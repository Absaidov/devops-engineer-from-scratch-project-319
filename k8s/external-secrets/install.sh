#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

KUBECTL_BIN="${KUBECTL:-kubectl}"
HELM_BIN="${HELM:-helm}"
YC_BIN="${YC:-yc}"
JQ_BIN="${JQ:-jq}"

APPLICATION_NAMESPACE="${K8S_NAMESPACE:-bulletins}"
OPERATOR_NAMESPACE="${EXTERNAL_SECRETS_NAMESPACE:-external-secrets-operator-space}"
OPERATOR_RELEASE="${EXTERNAL_SECRETS_RELEASE:-external-secrets}"
OPERATOR_CHART="${EXTERNAL_SECRETS_CHART:-oci://cr.yandex/yc-marketplace/yandex-cloud/external-secrets/charts/external-secrets}"
OPERATOR_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-2.5.0-2}"
OPERATOR_VALUES="${EXTERNAL_SECRETS_VALUES:-k8s/external-secrets/external-secrets-values.yaml}"
OPERATOR_SERVICE_ACCOUNT_NAME="${EXTERNAL_SECRETS_SERVICE_ACCOUNT_NAME:-project-319-external-secrets}"
OPERATOR_SERVICE_ACCOUNT_ID="${EXTERNAL_SECRETS_SERVICE_ACCOUNT_ID:-}"
STORE_MANIFEST="${EXTERNAL_SECRETS_STORE_MANIFEST:-k8s/external-secrets/cluster-secret-store.yaml}"
STORE_NAME="${EXTERNAL_SECRETS_STORE_NAME:-project-319-lockbox}"
ROTATE_AUTH_KEY="${EXTERNAL_SECRETS_ROTATE_AUTH_KEY:-false}"

RELOADER_NAMESPACE="${RELOADER_NAMESPACE:-reloader}"
RELOADER_RELEASE="${RELOADER_RELEASE:-reloader}"
RELOADER_CHART_VERSION="${RELOADER_CHART_VERSION:-2.2.17}"
RELOADER_VALUES="${RELOADER_VALUES:-k8s/external-secrets/reloader-values.yaml}"
WAIT_TIMEOUT="${EXTERNAL_SECRETS_WAIT_TIMEOUT:-300s}"

for command_name in "${KUBECTL_BIN}" "${HELM_BIN}" "${YC_BIN}" "${JQ_BIN}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is not installed: ${command_name}" >&2
        exit 1
    fi
done

for required_file in "${OPERATOR_VALUES}" "${RELOADER_VALUES}" "${STORE_MANIFEST}"; do
    if [[ ! -f "${required_file}" ]]; then
        echo "Required file does not exist: ${required_file}" >&2
        exit 1
    fi
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/project-319-external-secrets.XXXXXX")"
auth_file="${temporary_directory}/authorized-key.json"
existing_auth_file="${temporary_directory}/existing-authorized-key.json"
created_key_id=""
previous_key_id=""
credentials_installed=false

cleanup() {
    if [[ "${credentials_installed}" != "true" && -n "${created_key_id}" ]]; then
        "${YC_BIN}" iam key delete "${created_key_id}" --no-user-output >/dev/null 2>&1 || true
    fi
    rm -rf "${temporary_directory}"
}
trap cleanup EXIT INT TERM

if "${KUBECTL_BIN}" --namespace "${OPERATOR_NAMESPACE}" get secret/sa-creds >/dev/null 2>&1; then
    "${KUBECTL_BIN}" --namespace "${OPERATOR_NAMESPACE}" get secret/sa-creds --output json \
        | "${JQ_BIN}" -er '.data.key | @base64d' >"${existing_auth_file}"
    previous_key_id="$("${JQ_BIN}" -er '.id // empty' "${existing_auth_file}" || true)"
fi

if [[ -s "${existing_auth_file}" && "${ROTATE_AUTH_KEY}" != "true" ]]; then
    cp "${existing_auth_file}" "${auth_file}"
else
    if [[ -z "${OPERATOR_SERVICE_ACCOUNT_ID}" ]]; then
        OPERATOR_SERVICE_ACCOUNT_ID="$(
            "${YC_BIN}" iam service-account get \
                --name "${OPERATOR_SERVICE_ACCOUNT_NAME}" \
                --format json \
                | "${JQ_BIN}" -er '.id'
        )" || {
            echo "External Secrets service account is missing. Apply Terraform first." >&2
            exit 1
        }
    fi

    "${YC_BIN}" iam key create \
        --service-account-id "${OPERATOR_SERVICE_ACCOUNT_ID}" \
        --description "External Secrets Operator bootstrap key" \
        --output "${auth_file}" \
        --no-user-output
    created_key_id="$("${JQ_BIN}" -er '.id' "${auth_file}")"
fi

chmod 600 "${auth_file}"

if ! "${KUBECTL_BIN}" get "namespace/${APPLICATION_NAMESPACE}" >/dev/null 2>&1; then
    "${KUBECTL_BIN}" create namespace "${APPLICATION_NAMESPACE}"
fi

"${HELM_BIN}" upgrade --install "${OPERATOR_RELEASE}" "${OPERATOR_CHART}" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --create-namespace \
    --version "${OPERATOR_CHART_VERSION}" \
    --values "${OPERATOR_VALUES}" \
    --set-file "auth.json=${auth_file}" \
    --wait \
    --timeout "${WAIT_TIMEOUT}"
credentials_installed=true

"${KUBECTL_BIN}" apply --filename "${STORE_MANIFEST}"
"${KUBECTL_BIN}" wait \
    --for=condition=Ready \
    "clustersecretstore/${STORE_NAME}" \
    --timeout="${WAIT_TIMEOUT}"

"${HELM_BIN}" repo add stakater https://stakater.github.io/stakater-charts --force-update
"${HELM_BIN}" repo update stakater
"${HELM_BIN}" upgrade --install "${RELOADER_RELEASE}" stakater/reloader \
    --namespace "${RELOADER_NAMESPACE}" \
    --create-namespace \
    --version "${RELOADER_CHART_VERSION}" \
    --values "${RELOADER_VALUES}" \
    --wait \
    --timeout "${WAIT_TIMEOUT}"

if [[ "${ROTATE_AUTH_KEY}" == "true" && -n "${previous_key_id}" && "${previous_key_id}" != "${created_key_id}" ]]; then
    "${YC_BIN}" iam key delete "${previous_key_id}" --no-user-output
    echo "The previous External Secrets authorized key was revoked after the successful rollout."
fi

echo "External Secrets Operator and Reloader are ready."
echo "ClusterSecretStore: ${STORE_NAME}; allowed namespace: ${APPLICATION_NAMESPACE}."
