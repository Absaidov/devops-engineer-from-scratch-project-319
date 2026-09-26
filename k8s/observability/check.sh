#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL:-kubectl}"
TERRAFORM_BIN="${TERRAFORM:-terraform}"
TERRAFORM_DIRECTORY="${TERRAFORM_DIR:-terraform}"
PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-prometheus-operator-space}"
LOG_GROUP_NAME="${APPLICATION_LOG_GROUP_NAME:-project-319-application-logs}"
LOCKBOX_SECRET_NAME="${OBSERVABILITY_LOCKBOX_SECRET_NAME:-project-319-observability}"

for command_name in yc jq curl "${KUBECTL_BIN}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is not installed: ${command_name}" >&2
        exit 1
    fi
done

workspace_id="${PROMETHEUS_WORKSPACE_ID:-}"
if [[ -z "${workspace_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    workspace_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw prometheus_workspace_id 2>/dev/null || true)"
fi
if [[ ! "${workspace_id}" =~ ^[a-z0-9]+$ ]]; then
    echo "Set PROMETHEUS_WORKSPACE_ID before running this check." >&2
    exit 1
fi

log_group_id="${APPLICATION_LOG_GROUP_ID:-}"
if [[ -z "${log_group_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    log_group_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw application_log_group_id 2>/dev/null || true)"
fi
if [[ -z "${log_group_id}" ]]; then
    log_group_id="$(yc logging group get --name "${LOG_GROUP_NAME}" --format json | jq -er '.id')"
fi

lockbox_secret_id="${OBSERVABILITY_LOCKBOX_SECRET_ID:-}"
if [[ -z "${lockbox_secret_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    lockbox_secret_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw observability_lockbox_secret_id 2>/dev/null || true)"
fi
if [[ -z "${lockbox_secret_id}" ]]; then
    lockbox_secret_id="$(yc lockbox secret get --name "${LOCKBOX_SECRET_NAME}" --format json | jq -er '.id')"
fi
api_key="$(
    yc lockbox payload get "${lockbox_secret_id}" --format json \
        | jq -er '.entries[] | select(.key == "PROMETHEUS_API_KEY") | .text_value'
)"

"${KUBECTL_BIN}" --namespace logging rollout status daemonset/fluent-bit --timeout=30s
"${KUBECTL_BIN}" --namespace "${PROMETHEUS_NAMESPACE}" get pods
"${KUBECTL_BIN}" --namespace bulletins get servicemonitor bulletins
"${KUBECTL_BIN}" --namespace bulletins get prometheusrule bulletins

port_forward_log="${TMPDIR:-/tmp}/project-319-observability-port-forward.log"
"${KUBECTL_BIN}" --namespace bulletins port-forward service/bulletins \
    18081:80 19091:9090 \
    >"${port_forward_log}" 2>&1 &
port_forward_pid=$!
trap 'kill "${port_forward_pid}" 2>/dev/null || true; wait "${port_forward_pid}" 2>/dev/null || true; unset api_key' EXIT INT TERM

application_ready=0
for _ in $(seq 1 30); do
    if curl --fail --silent --output /dev/null \
        http://127.0.0.1:18081/api/bulletins; then
        application_ready=1
        break
    fi
    sleep 1
done
if [[ "${application_ready}" -ne 1 ]]; then
    tail -n 50 "${port_forward_log}" >&2
    echo "The application API is not ready through the Kubernetes Service." >&2
    exit 1
fi

local_metrics_ready=0
for _ in $(seq 1 30); do
    local_metrics="$(curl --fail --silent http://127.0.0.1:19091/actuator/prometheus || true)"
    if grep -q '^http_server_requests_seconds_count' <<<"${local_metrics}"; then
        local_metrics_ready=1
        break
    fi
    sleep 1
done
if [[ "${local_metrics_ready}" -ne 1 ]]; then
    tail -n 50 "${port_forward_log}" >&2
    echo "The application Prometheus endpoint is not ready." >&2
    exit 1
fi

log_marker="project319-observability-check-$(date +%s)"
"${KUBECTL_BIN}" --namespace bulletins exec deployment/bulletins \
    --container application -- \
    sh -c 'printf "%s\n" "$1" > /proc/1/fd/1' sh "${log_marker}"

prometheus_query() {
    local query="$1"
    curl --fail --silent --show-error --get \
        --header "Authorization: Api-Key ${api_key}" \
        --data-urlencode "query=${query}" \
        "https://monitoring.api.cloud.yandex.net/prometheus/workspaces/${workspace_id}/api/v1/query"
}

metrics_ready=0
for _ in $(seq 1 18); do
    up_response="$(prometheus_query 'count(up{namespace="bulletins",service="bulletins"} == 1)')"
    app_response="$(prometheus_query 'count(http_server_requests_seconds_count{namespace="bulletins"})')"
    running_response="$(prometheus_query 'count(kube_pod_status_phase{namespace="bulletins",phase="Running"} == 1)')"

    up_count="$(jq -r '.data.result[0].value[1] // "0"' <<<"${up_response}")"
    app_count="$(jq -r '.data.result[0].value[1] // "0"' <<<"${app_response}")"
    running_count="$(jq -r '.data.result[0].value[1] // "0"' <<<"${running_response}")"

    if awk "BEGIN {exit !(${up_count} >= 1 && ${app_count} >= 1 && ${running_count} >= 2)}"; then
        metrics_ready=1
        break
    fi
    sleep 10
done
if [[ "${metrics_ready}" -ne 1 ]]; then
    echo "Managed Prometheus metrics did not become ready within three minutes." >&2
    exit 1
fi

logs_ready=0
for _ in $(seq 1 12); do
    logs_until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    logs_json="$(
        yc logging read \
            --group-id "${log_group_id}" \
            --since 10m \
            --until "${logs_until}" \
            --filter 'resource_type = "bulletins"' \
            --limit 100 \
            --format json
    )"
    if jq --exit-status --arg marker "${log_marker}" \
        'any(.[]; (.message // "") == $marker)' \
        >/dev/null <<<"${logs_json}"; then
        logs_ready=1
        break
    fi
    sleep 10
done
if [[ "${logs_ready}" -ne 1 ]]; then
    echo "The end-to-end test record did not reach Cloud Logging." >&2
    echo "Inspect Fluent Bit with: kubectl -n logging logs daemonset/fluent-bit --tail=100" >&2
    exit 1
fi

log_count="$(
    jq --arg marker "${log_marker}" \
        '[.[] | select((.message // "") == $marker)] | length' \
        <<<"${logs_json}"
)"

echo "Managed Prometheus: up=${up_count}, application series=${app_count}, running pods=${running_count}."
echo "Cloud Logging: ${log_count} end-to-end test record found."
echo "Managed metrics and pod log delivery are working end to end."
