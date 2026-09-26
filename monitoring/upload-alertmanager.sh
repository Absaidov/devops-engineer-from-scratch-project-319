#!/usr/bin/env bash

set -Eeuo pipefail

TERRAFORM_BIN="${TERRAFORM:-terraform}"
TERRAFORM_DIRECTORY="${TERRAFORM_DIR:-terraform}"
MONITORING_DIRECTORY="${MONITORING_DIR:-monitoring}"
notification_channel="${MONITORING_NOTIFICATION_CHANNEL:-}"

for command_name in yc curl jq base64 sed tr; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is not installed: ${command_name}" >&2
        exit 1
    fi
done

if [[ -z "${notification_channel}" ]]; then
    echo "Set MONITORING_NOTIFICATION_CHANNEL to an existing Yandex Monitoring channel name." >&2
    exit 1
fi
if [[ ! "${notification_channel}" =~ ^[[:alnum:]_.\ -]+$ ]]; then
    echo "The channel name may contain letters, digits, spaces, dots, underscores and hyphens only." >&2
    exit 1
fi

workspace_id="${PROMETHEUS_WORKSPACE_ID:-}"
if [[ -z "${workspace_id}" ]] && command -v "${TERRAFORM_BIN}" >/dev/null 2>&1; then
    workspace_id="$(${TERRAFORM_BIN} -chdir="${TERRAFORM_DIRECTORY}" output -raw prometheus_workspace_id 2>/dev/null || true)"
fi
if [[ ! "${workspace_id}" =~ ^[a-z0-9]+$ ]]; then
    echo "Set PROMETHEUS_WORKSPACE_ID to the Managed Prometheus workspace ID." >&2
    exit 1
fi

iam_token="${YC_TOKEN:-}"
if [[ -z "${iam_token}" ]]; then
    iam_token="$(yc iam create-token)"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/project-319-alertmanager.XXXXXX")"
rendered_config="${temporary_directory}/alertmanager.yml"
request_body="${temporary_directory}/request.json"
response_body="${temporary_directory}/response.txt"
trap 'rm -rf "${temporary_directory}"; unset iam_token' EXIT INT TERM
chmod 700 "${temporary_directory}"

sed "s|__NOTIFICATION_CHANNEL__|${notification_channel}|g" \
    "${MONITORING_DIRECTORY}/alertmanager.yml.tpl" \
    >"${rendered_config}"

encoded_config="$(base64 <"${rendered_config}" | tr -d '\n')"
jq --null-input --arg content "${encoded_config}" '{content: $content}' >"${request_body}"
unset encoded_config

http_status="$(
    curl --silent --show-error \
        --output "${response_body}" \
        --write-out '%{http_code}' \
        --request PUT \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer ${iam_token}" \
        --data-binary "@${request_body}" \
        "https://monitoring.api.cloud.yandex.net/prometheus/workspaces/${workspace_id}/extensions/v1/alertmanager"
)"

if [[ "${http_status}" != "204" ]]; then
    echo "Alertmanager configuration upload failed with HTTP ${http_status}:" >&2
    cat "${response_body}" >&2
    exit 1
fi

echo "Alertmanager routing is configured for channel: ${notification_channel}"
echo "Managed Prometheus workspace: ${workspace_id}"
