#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL:-kubectl}"
YC_BIN="${YC:-yc}"
JQ_BIN="${JQ:-jq}"
CURL_BIN="${CURL:-curl}"

NAMESPACE="${K8S_NAMESPACE:-bulletins}"
DEPLOYMENT="${K8S_DEPLOYMENT:-bulletins}"
PUBLIC_SERVICE="${K8S_PUBLIC_SERVICE:-bulletins-public}"
EXTERNAL_SECRET_NAME="${EXTERNAL_SECRET_NAME:-bulletins}"
TARGET_SECRET_NAME="${K8S_SECRET_NAME:-bulletins-secrets}"
LOCKBOX_SECRET_NAME="${K8S_LOCKBOX_SECRET_NAME:-project-319-application}"
LOCKBOX_SECRET_ID="${K8S_LOCKBOX_SECRET_ID:-}"
WAIT_TIMEOUT_SECONDS="${ROTATION_WAIT_TIMEOUT_SECONDS:-300}"
PROBE_INTERVAL="${ROTATION_PROBE_INTERVAL:-0.25}"

for command_name in "${KUBECTL_BIN}" "${YC_BIN}" "${JQ_BIN}" "${CURL_BIN}" openssl shasum awk; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is not installed: ${command_name}" >&2
        exit 1
    fi
done

if [[ -z "${LOCKBOX_SECRET_ID}" ]]; then
    LOCKBOX_SECRET_ID="$(
        "${YC_BIN}" lockbox secret get \
            --name "${LOCKBOX_SECRET_NAME}" \
            --format json \
            | "${JQ_BIN}" -er '.id'
    )"
fi

"${KUBECTL_BIN}" --namespace "${NAMESPACE}" wait \
    --for=condition=Ready \
    "externalsecret/${EXTERNAL_SECRET_NAME}" \
    --timeout=60s

hash_secret_key() {
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "secret/${TARGET_SECRET_NAME}" --output json \
        | "${JQ_BIN}" -ej '.data.ROTATION_MARKER | @base64d' \
        | shasum -a 256 \
        | awk '{print $1}'
}

old_hash="$(hash_secret_key)"
old_resource_version="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "secret/${TARGET_SECRET_NAME}" \
        --output jsonpath='{.metadata.resourceVersion}'
)"
old_generation="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
        --output jsonpath='{.metadata.generation}'
)"
old_pod_uids="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pods \
        --selector app.kubernetes.io/name=bulletins,app.kubernetes.io/component=application \
        --output json \
        | "${JQ_BIN}" -r '[.items[].metadata.uid] | sort | join(",")'
)"

public_address="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "service/${PUBLIC_SERVICE}" --output json \
        | "${JQ_BIN}" -er '.status.loadBalancer.ingress[0] | .ip // .hostname'
)"
probe_url="http://${public_address}/api/bulletins"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/project-319-secret-rotation.XXXXXX")"
probe_log="${temporary_directory}/http-statuses.log"
stop_file="${temporary_directory}/stop"
probe_pid=""

cleanup() {
    : >"${stop_file}" 2>/dev/null || true
    if [[ -n "${probe_pid}" ]]; then
        wait "${probe_pid}" 2>/dev/null || true
    fi
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

(
    while [[ ! -e "${stop_file}" ]]; do
        status_code="$(
            "${CURL_BIN}" \
                --silent \
                --output /dev/null \
                --write-out '%{http_code}' \
                --connect-timeout 3 \
                --max-time 5 \
                "${probe_url}" || true
        )"
        if [[ ! "${status_code}" =~ ^[0-9]{3}$ ]]; then
            status_code="000"
        fi
        printf '%s\n' "${status_code}" >>"${probe_log}"
        sleep "${PROBE_INTERVAL}"
    done
) &
probe_pid=$!

rotation_value="$(openssl rand -hex 24)"
expected_hash="$(printf '%s' "${rotation_value}" | shasum -a 256 | awk '{print $1}')"
payload="$("${JQ_BIN}" -nc --arg value "${rotation_value}" '[{key:"ROTATION_MARKER", text_value:$value}]')"
base_version_id="$(
    "${YC_BIN}" lockbox secret get --id "${LOCKBOX_SECRET_ID}" --format json \
        | "${JQ_BIN}" -er '.current_version.id'
)"
version_response="$(
    printf '%s' "${payload}" \
        | "${YC_BIN}" lockbox secret add-version \
            --id "${LOCKBOX_SECRET_ID}" \
            --base-version-id "${base_version_id}" \
            --description "External Secrets automatic rotation verification" \
            --payload - \
            --format json
)"
new_version_id="$("${JQ_BIN}" -er '.id' <<<"${version_response}")"
unset rotation_value payload version_response base_version_id

secret_updated=false
for ((attempt = 0; attempt < WAIT_TIMEOUT_SECONDS; attempt += 2)); do
    current_resource_version="$(
        "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "secret/${TARGET_SECRET_NAME}" \
            --output jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true
    )"
    current_hash="$(hash_secret_key 2>/dev/null || true)"
    if [[ "${current_resource_version}" != "${old_resource_version}" && "${current_hash}" == "${expected_hash}" ]]; then
        secret_updated=true
        break
    fi
    sleep 2
done

if [[ "${secret_updated}" != "true" ]]; then
    echo "Timed out waiting for External Secrets Operator to synchronize the new Lockbox version." >&2
    exit 1
fi

rollout_started=false
for ((attempt = 0; attempt < WAIT_TIMEOUT_SECONDS; attempt += 2)); do
    current_generation="$(
        "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "deployment/${DEPLOYMENT}" \
            --output jsonpath='{.metadata.generation}'
    )"
    if ((current_generation > old_generation)); then
        rollout_started=true
        break
    fi
    sleep 2
done

if [[ "${rollout_started}" != "true" ]]; then
    echo "The Kubernetes Secret changed, but Reloader did not start a new Deployment generation." >&2
    exit 1
fi

"${KUBECTL_BIN}" --namespace "${NAMESPACE}" rollout status \
    "deployment/${DEPLOYMENT}" \
    --timeout="${WAIT_TIMEOUT_SECONDS}s"

deployment_json="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "deployment/${DEPLOYMENT}" --output json
)"
desired_replicas="$("${JQ_BIN}" -er '.spec.replicas' <<<"${deployment_json}")"
ready_replicas="$("${JQ_BIN}" -r '.status.readyReplicas // 0' <<<"${deployment_json}")"
unset deployment_json

new_pod_uids="$(
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pods \
        --selector app.kubernetes.io/name=bulletins,app.kubernetes.io/component=application \
        --output json \
        | "${JQ_BIN}" -r '[.items[].metadata.uid] | sort | join(",")'
)"

if [[ "${ready_replicas}" != "${desired_replicas}" ]]; then
    echo "Deployment is not fully Ready after rotation: ${ready_replicas}/${desired_replicas}." >&2
    exit 1
fi
if [[ "${old_pod_uids}" == "${new_pod_uids}" ]]; then
    echo "Secret was updated, but application pods were not replaced." >&2
    exit 1
fi
if [[ "${old_hash}" == "${expected_hash}" ]]; then
    echo "The generated marker unexpectedly matches the previous marker." >&2
    exit 1
fi

: >"${stop_file}"
wait "${probe_pid}" 2>/dev/null || true
probe_pid=""

total_requests="$(awk 'END {print NR + 0}' "${probe_log}")"
failed_requests="$(awk '$1 !~ /^2[0-9][0-9]$/ && $1 !~ /^3[0-9][0-9]$/ {count++} END {print count + 0}' "${probe_log}")"
server_errors="$(awk '$1 ~ /^5[0-9][0-9]$/ {count++} END {print count + 0}' "${probe_log}")"

if [[ "${total_requests}" -eq 0 || "${failed_requests}" -ne 0 || "${server_errors}" -ne 0 ]]; then
    echo "Rotation availability check failed: total=${total_requests}, failed=${failed_requests}, 5xx=${server_errors}." >&2
    exit 1
fi

echo "Lockbox version ${new_version_id} was synchronized without exposing its payload."
echo "ExternalSecret is Ready; Secret resourceVersion changed; all ${ready_replicas} replicas are Ready."
echo "Reloader replaced the application pods automatically."
echo "HTTP requests during rotation: total=${total_requests}, failed=${failed_requests}, 5xx=${server_errors}."
echo "Automatic zero-downtime secret rotation verified successfully."
