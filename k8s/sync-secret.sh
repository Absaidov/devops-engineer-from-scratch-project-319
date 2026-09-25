#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE="${K8S_NAMESPACE:-bulletins}"
SECRET_NAME="${K8S_SECRET_NAME:-bulletins-secrets}"
LOCKBOX_SECRET_NAME="${K8S_LOCKBOX_SECRET_NAME:-project-319-application}"

for command_name in yc jq "${KUBECTL_BIN}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Required command is not installed: ${command_name}" >&2
        exit 1
    fi
done

secret_id="${K8S_LOCKBOX_SECRET_ID:-}"
if [[ -z "${secret_id}" ]]; then
    secret_id="$(
        yc lockbox secret get \
            --name "${LOCKBOX_SECRET_NAME}" \
            --format json \
            | jq -er '.id'
    )"
fi
payload="$(yc lockbox payload get "${secret_id}" --format json)"

read_secret() {
    local key="$1"
    local value

    value="$(jq -er --arg key "${key}" '.entries[] | select(.key == $key) | .text_value' <<<"${payload}")" || {
        echo "Lockbox entry is missing: ${key}" >&2
        exit 1
    }

    printf '%s' "${value}"
}

db_host="$(read_secret DB_HOST)"
db_port="$(read_secret DB_PORT)"
db_name="$(read_secret DB_NAME)"
db_user="$(read_secret DB_USER)"
db_password="$(read_secret DB_PASSWORD)"
s3_bucket="$(read_secret S3_BUCKET)"
s3_access_key="$(read_secret S3_ACCESS_KEY)"
s3_secret_key="$(read_secret S3_SECRET_KEY)"
database_url="jdbc:postgresql://${db_host}:${db_port}/${db_name}?sslmode=require&targetServerType=master&loadBalanceHosts=true"

"${KUBECTL_BIN}" create secret generic "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --from-literal="SPRING_DATASOURCE_URL=${database_url}" \
    --from-literal="SPRING_DATASOURCE_USERNAME=${db_user}" \
    --from-literal="SPRING_DATASOURCE_PASSWORD=${db_password}" \
    --from-literal="STORAGE_S3_BUCKET=${s3_bucket}" \
    --from-literal="STORAGE_S3_ACCESSKEY=${s3_access_key}" \
    --from-literal="STORAGE_S3_SECRETKEY=${s3_secret_key}" \
    --dry-run=client \
    --output yaml \
    | "${KUBECTL_BIN}" apply --filename -

unset payload db_password s3_secret_key database_url
echo "Kubernetes Secret ${NAMESPACE}/${SECRET_NAME} is synchronized from Lockbox."
