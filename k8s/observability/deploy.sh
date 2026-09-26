#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL:-kubectl}"
HELM_BIN="${HELM:-helm}"
TERRAFORM_BIN="${TERRAFORM:-terraform}"
TERRAFORM_DIRECTORY="${TERRAFORM_DIR:-terraform}"
OBSERVABILITY_DIRECTORY="${K8S_OBSERVABILITY_DIR:-k8s/observability}"
PROMETHEUS_NAMESPACE="${PROMETHEUS_NAMESPACE:-prometheus-operator-space}"
PROMETHEUS_RELEASE="prometheus"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-88.5.2-1}"
LOG_GROUP_NAME="${APPLICATION_LOG_GROUP_NAME:-project-319-application-logs}"
LOCKBOX_SECRET_NAME="${OBSERVABILITY_LOCKBOX_SECRET_NAME:-project-319-observability}"

for command_name in yc jq curl sed "${KUBECTL_BIN}" "${HELM_BIN}"; do
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
    echo "Set PROMETHEUS_WORKSPACE_ID to the Managed Prometheus workspace ID." >&2
    echo "You may also set prometheus_workspace_id in terraform/terraform.tfvars and apply Terraform first." >&2
    exit 1
fi

log_group_id="${APPLICATION_LOG_GROUP_ID:-}"
if [[ -z "${log_group_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    log_group_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw application_log_group_id 2>/dev/null || true)"
fi
if [[ -z "${log_group_id}" ]]; then
    log_group_id="$(
        yc logging group get \
            --name "${LOG_GROUP_NAME}" \
            --format json \
            | jq -er '.id'
    )"
fi
if [[ ! "${log_group_id}" =~ ^[a-z0-9]+$ ]]; then
    echo "Unable to resolve Cloud Logging group ID." >&2
    exit 1
fi

lockbox_secret_id="${OBSERVABILITY_LOCKBOX_SECRET_ID:-}"
if [[ -z "${lockbox_secret_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    lockbox_secret_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw observability_lockbox_secret_id 2>/dev/null || true)"
fi
if [[ -z "${lockbox_secret_id}" ]]; then
    lockbox_secret_id="$(
        yc lockbox secret get \
            --name "${LOCKBOX_SECRET_NAME}" \
            --format json \
            | jq -er '.id'
    )"
fi

api_key="$(
    yc lockbox payload get "${lockbox_secret_id}" --format json \
        | jq -er '.entries[] | select(.key == "PROMETHEUS_API_KEY") | .text_value'
)"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/project-319-observability.XXXXXX")"
api_key_file="${temporary_directory}/prometheus-api-key"
rendered_fluent_bit="${temporary_directory}/fluent-bit-config.yaml"
trap 'rm -rf "${temporary_directory}"' EXIT INT TERM
chmod 700 "${temporary_directory}"
printf '%s' "${api_key}" >"${api_key_file}"
chmod 600 "${api_key_file}"
unset api_key

sed "s/__LOG_GROUP_ID__/${log_group_id}/g" \
    "${OBSERVABILITY_DIRECTORY}/fluent-bit-config.yaml.tpl" \
    >"${rendered_fluent_bit}"

"${KUBECTL_BIN}" apply --filename "${OBSERVABILITY_DIRECTORY}/fluent-bit-rbac.yaml"
"${KUBECTL_BIN}" apply --filename "${rendered_fluent_bit}"
"${KUBECTL_BIN}" apply --filename "${OBSERVABILITY_DIRECTORY}/fluent-bit-daemonset.yaml"

"${HELM_BIN}" pull \
    oci://cr.yandex/yc-marketplace/yandex-cloud/prometheus/charts/kube-prometheus-stack \
    --version "${PROMETHEUS_CHART_VERSION}" \
    --untar \
    --untardir "${temporary_directory}"

"${HELM_BIN}" upgrade --install "${PROMETHEUS_RELEASE}" \
    "${temporary_directory}/kube-prometheus-stack" \
    --namespace "${PROMETHEUS_NAMESPACE}" \
    --create-namespace \
    --values "${OBSERVABILITY_DIRECTORY}/prometheus-values.yaml" \
    --set-string "prometheusWorkspaceId=${workspace_id}" \
    --set-file "iam_api_key_value_generated.secretAccessKey=${api_key_file}" \
    --wait \
    --timeout 10m

"${KUBECTL_BIN}" apply --filename "${OBSERVABILITY_DIRECTORY}/service-monitor.yaml"
"${KUBECTL_BIN}" apply --filename "${OBSERVABILITY_DIRECTORY}/prometheus-rules.yaml"
"${KUBECTL_BIN}" --namespace logging rollout status daemonset/fluent-bit --timeout=300s

echo "Managed observability components are deployed."
echo "Prometheus workspace: ${workspace_id}"
echo "Cloud Logging group: ${log_group_id}"
