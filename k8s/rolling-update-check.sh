#!/usr/bin/env bash

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
K8S_NAMESPACE="${K8S_NAMESPACE:-bulletins}"
K8S_DEPLOYMENT="${K8S_DEPLOYMENT:-bulletins}"
K8S_SERVICE="${K8S_SERVICE:-bulletins}"
K8S_PUBLIC_SERVICE="${K8S_PUBLIC_SERVICE:-bulletins-public}"
K8S_CONTAINER="${K8S_CONTAINER:-application}"
K8S_NEW_IMAGE="${K8S_NEW_IMAGE:-}"
K8S_DISTRIBUTION_REQUESTS="${K8S_DISTRIBUTION_REQUESTS:-60}"
K8S_ROLLOUT_TIMEOUT="${K8S_ROLLOUT_TIMEOUT:-300s}"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/project-319-rollout.XXXXXX")"
status_log="${work_directory}/http-statuses.log"
traffic_pid=""
rollout_started=0

cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "${traffic_pid}" ]] && kill -0 "${traffic_pid}" 2>/dev/null; then
    kill "${traffic_pid}" 2>/dev/null || true
    wait "${traffic_pid}" 2>/dev/null || true
  fi
  if [[ "${exit_status}" -ne 0 && "${rollout_started}" -eq 1 ]]; then
    echo "The rollout check failed after starting the update." >&2
    echo "Inspect it with: kubectl -n ${K8S_NAMESPACE} rollout status deployment/${K8S_DEPLOYMENT}" >&2
    echo "Rollback if necessary: kubectl -n ${K8S_NAMESPACE} rollout undo deployment/${K8S_DEPLOYMENT}" >&2
  fi
  rm -rf "${work_directory}"
  exit "${exit_status}"
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

get_ready_pods() {
  ${KUBECTL} --namespace "${K8S_NAMESPACE}" get pods \
    --selector 'app.kubernetes.io/name=bulletins,app.kubernetes.io/component=application' \
    --output 'custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,DELETING:.metadata.deletionTimestamp' \
    --no-headers | awk '$2 == "true" && $3 == "<none>" { print $1 }'
}

get_ready_image_ids() {
  local pod

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    ${KUBECTL} --namespace "${K8S_NAMESPACE}" get pod "${pod}" \
      --output jsonpath='{.status.containerStatuses[0].imageID}'
    echo
  done < <(get_ready_pods)
}

get_ready_pod_uids() {
  local pod

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    ${KUBECTL} --namespace "${K8S_NAMESPACE}" get pod "${pod}" \
      --output jsonpath='{.metadata.uid}'
    echo
  done < <(get_ready_pods)
}

get_request_count() {
  local pod="$1"

  ${KUBECTL} get --raw \
    "/api/v1/namespaces/${K8S_NAMESPACE}/pods/${pod}:9090/proxy/actuator/prometheus" \
    | awk '/^http_server_requests_seconds_count\{/ && /method="GET"/ && /status="200"/ && /uri="\/api\/bulletins"/ { total += $NF } END { print total + 0 }'
}

verify_redundancy() {
  local stage="$1"
  local desired_replicas
  local ready_replicas
  local ready_endpoints
  local ready_endpoint_count
  local ready_nodes
  local ready_node_count

  desired_replicas="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get deployment \
    "${K8S_DEPLOYMENT}" --output jsonpath='{.spec.replicas}')"
  ready_replicas="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get deployment \
    "${K8S_DEPLOYMENT}" --output jsonpath='{.status.readyReplicas}')"
  ready_replicas="${ready_replicas:-0}"

  if [[ "${desired_replicas}" -lt 2 || "${ready_replicas}" -lt 2 ]]; then
    echo "${stage}: expected at least two Ready replicas, got ${ready_replicas}/${desired_replicas}." >&2
    exit 1
  fi

  ready_endpoints="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get endpointslice \
    --selector "kubernetes.io/service-name=${K8S_SERVICE}" \
    --output go-template='{{range .items}}{{range .endpoints}}{{if .conditions.ready}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}')"
  ready_endpoint_count="$(printf '%s\n' "${ready_endpoints}" | awk 'NF { count += 1 } END { print count + 0 }')"

  if [[ "${ready_endpoint_count}" -lt 2 ]]; then
    echo "${stage}: expected at least two Ready service endpoints, got ${ready_endpoint_count}." >&2
    exit 1
  fi

  ready_nodes="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get pods \
    --selector 'app.kubernetes.io/name=bulletins,app.kubernetes.io/component=application' \
    --output 'custom-columns=NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,DELETING:.metadata.deletionTimestamp' \
    --no-headers | awk '$2 == "true" && $3 == "<none>" { print $1 }' | sort -u)"
  ready_node_count="$(printf '%s\n' "${ready_nodes}" | awk 'NF { count += 1 } END { print count + 0 }')"

  if [[ "${ready_node_count}" -lt 2 ]]; then
    echo "${stage}: Ready application pods are not spread across two nodes." >&2
    exit 1
  fi

  echo "${stage}: ${ready_replicas} Ready replicas, ${ready_endpoint_count} endpoints, ${ready_node_count} nodes."
}

verify_traffic_distribution() {
  local ready_pods
  local pod
  local before_count
  local after_count
  local request_delta
  local pods_with_requests=0
  local distribution_log="${work_directory}/distribution.log"
  local status_code
  local min_delta
  local max_delta
  local request

  ready_pods="$(get_ready_pods)"

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    get_request_count "${pod}" >"${work_directory}/baseline-${pod}"
  done <<<"${ready_pods}"

  for ((request = 1; request <= K8S_DISTRIBUTION_REQUESTS; request += 1)); do
    status_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 3 --max-time 10 "${public_url}" 2>/dev/null)" || status_code="000"
    printf '%s\n' "${status_code}" >>"${status_log}"
  done

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    before_count="$(cat "${work_directory}/baseline-${pod}")"
    after_count="$(get_request_count "${pod}")"
    request_delta="$(awk -v before="${before_count}" -v after="${after_count}" \
      'BEGIN { print after - before }')"
    printf '%s %s\n' "${pod}" "${request_delta}" | tee -a "${distribution_log}"
    if awk -v value="${request_delta}" 'BEGIN { exit !(value > 0) }'; then
      pods_with_requests=$((pods_with_requests + 1))
    fi
  done <<<"${ready_pods}"

  if [[ "${pods_with_requests}" -lt 2 ]]; then
    echo "Public requests did not reach both Ready application pods." >&2
    exit 1
  fi

  min_delta="$(awk 'NR == 1 || $2 < min { min = $2 } END { print min + 0 }' "${distribution_log}")"
  max_delta="$(awk 'NR == 1 || $2 > max { max = $2 } END { print max + 0 }' "${distribution_log}")"
  if ! awk -v min="${min_delta}" -v max="${max_delta}" \
    'BEGIN { exit !(min > 0 && max <= min * 4) }'; then
    echo "Traffic distribution is too uneven: min=${min_delta}, max=${max_delta}." >&2
    exit 1
  fi

  echo "Traffic reached both pods without more than a 4:1 imbalance."
}

public_address=""
for ((attempt = 1; attempt <= 60; attempt += 1)); do
  public_address="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get service \
    "${K8S_PUBLIC_SERVICE}" \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -z "${public_address}" ]]; then
    public_address="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get service \
      "${K8S_PUBLIC_SERVICE}" \
      --output jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi
  [[ -n "${public_address}" ]] && break
  sleep 5
done

if [[ -z "${public_address}" ]]; then
  echo "The public load balancer has no external address." >&2
  exit 1
fi

public_url="http://${public_address}/api/bulletins"
current_image="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get deployment \
  "${K8S_DEPLOYMENT}" \
  --output jsonpath='{.spec.template.spec.containers[0].image}')"
current_image_ids="$(get_ready_image_ids | awk 'NF' | sort -u)"
current_pod_uids="$(get_ready_pod_uids | awk 'NF' | sort -u)"
current_revision="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get deployment \
  "${K8S_DEPLOYMENT}" \
  --output jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"

rollout_mode="image"
if [[ -z "${K8S_NEW_IMAGE}" || "${current_image}" == "${K8S_NEW_IMAGE}" ]]; then
  rollout_mode="restart"
  K8S_NEW_IMAGE="${current_image}"
fi

verify_redundancy "Before rollout"

preflight_status="$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' --connect-timeout 5 --max-time 15 \
  "${public_url}")" || preflight_status="000"
case "${preflight_status}" in
  2??) ;;
  *)
    echo "Public preflight request failed with HTTP ${preflight_status}." >&2
    exit 1
    ;;
esac

(
  while :; do
    status_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 3 --max-time 10 "${public_url}" 2>/dev/null)" || status_code="000"
    case "${status_code}" in
      [0-9][0-9][0-9]) ;;
      *) status_code="000" ;;
    esac
    printf '%s\n' "${status_code}" >>"${status_log}"
    sleep 0.2
  done
) &
traffic_pid=$!

sleep 2
rollout_started=1
if [[ "${rollout_mode}" == "restart" ]]; then
  echo "Rolling restart with the existing image: ${current_image}"
  ${KUBECTL} --namespace "${K8S_NAMESPACE}" rollout restart \
    "deployment/${K8S_DEPLOYMENT}"
else
  echo "Rolling ${current_image} -> ${K8S_NEW_IMAGE}"
  ${KUBECTL} --namespace "${K8S_NAMESPACE}" set image \
    "deployment/${K8S_DEPLOYMENT}" "${K8S_CONTAINER}=${K8S_NEW_IMAGE}"
fi
${KUBECTL} --namespace "${K8S_NAMESPACE}" rollout status \
  "deployment/${K8S_DEPLOYMENT}" --timeout="${K8S_ROLLOUT_TIMEOUT}"
sleep 5

kill "${traffic_pid}" 2>/dev/null || true
wait "${traffic_pid}" 2>/dev/null || true
traffic_pid=""

verify_redundancy "After rollout"
new_pod_uids="$(get_ready_pod_uids | awk 'NF' | sort -u)"
new_revision="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get deployment \
  "${K8S_DEPLOYMENT}" \
  --output jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"
if [[ -z "${new_pod_uids}" || "${new_pod_uids}" == "${current_pod_uids}" ]]; then
  echo "The Deployment finished, but the application pods were not replaced." >&2
  exit 1
fi
if [[ -z "${new_revision}" || "${new_revision}" == "${current_revision}" ]]; then
  echo "The Deployment revision did not change." >&2
  exit 1
fi

new_image_ids="$(get_ready_image_ids | awk 'NF' | sort -u)"
if [[ "${rollout_mode}" == "image" && ( -z "${new_image_ids}" || "${new_image_ids}" == "${current_image_ids}" ) ]]; then
  echo "The image reference changed, but the running image digest did not." >&2
  echo "Publish a genuinely new image before checking the rollout." >&2
  exit 1
fi
if [[ "${rollout_mode}" == "restart" ]]; then
  echo "Deployment revision ${current_revision} -> ${new_revision}; all pods were replaced using the existing image digest."
fi
verify_traffic_distribution

total_requests="$(wc -l <"${status_log}" | tr -d ' ')"
failed_requests="$(awk '$0 !~ /^2[0-9][0-9]$/ { count += 1 } END { print count + 0 }' "${status_log}")"
server_errors="$(awk '$0 ~ /^5[0-9][0-9]$/ { count += 1 } END { print count + 0 }' "${status_log}")"

echo "HTTP requests during rollout: total=${total_requests}, failed=${failed_requests}, 5xx=${server_errors}"
if [[ "${total_requests}" -lt 10 ]]; then
  echo "Not enough requests were recorded to validate the rollout." >&2
  exit 1
fi
if [[ "${failed_requests}" -ne 0 ]]; then
  echo "Zero-downtime verification failed." >&2
  exit 1
fi

echo "Zero-downtime rolling update verified successfully."
