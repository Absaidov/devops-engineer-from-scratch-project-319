#!/usr/bin/env bash

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE="${K8S_NAMESPACE:-bulletins}"
RELEASE_NAME="${HELM_RELEASE:-bulletins}"

if ! command -v "${KUBECTL_BIN}" >/dev/null 2>&1; then
    echo "Required command is not installed: ${KUBECTL_BIN}" >&2
    exit 1
fi

resources=(
    "configmap/bulletins-config"
    "configmap/bulletins-migrations"
    "deployment/bulletins"
    "service/bulletins"
    "service/bulletins-public"
    "poddisruptionbudget/bulletins"
)

adopted=0
for resource in "${resources[@]}"; do
    if ! "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get "${resource}" >/dev/null 2>&1; then
        continue
    fi

    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" label "${resource}" \
        app.kubernetes.io/managed-by=Helm \
        --overwrite >/dev/null
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" annotate "${resource}" \
        "meta.helm.sh/release-name=${RELEASE_NAME}" \
        "meta.helm.sh/release-namespace=${NAMESPACE}" \
        --overwrite >/dev/null
    echo "Prepared for Helm ownership: ${NAMESPACE}/${resource}"
    adopted=$((adopted + 1))
done

if [[ "${adopted}" -eq 0 ]]; then
    echo "No pre-Helm application resources found; Helm will create them."
else
    echo "Prepared ${adopted} existing application resources for release ${RELEASE_NAME}."
fi

echo "The external Secret and namespace remain outside Helm ownership."

