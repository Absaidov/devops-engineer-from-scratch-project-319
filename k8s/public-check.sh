#!/usr/bin/env bash

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
K8S_NAMESPACE="${K8S_NAMESPACE:-bulletins}"
K8S_PUBLIC_SERVICE="${K8S_PUBLIC_SERVICE:-bulletins-public}"
K8S_PUBLIC_CHECK_REQUESTS="${K8S_PUBLIC_CHECK_REQUESTS:-20}"
K8S_PUBLIC_WAIT_ATTEMPTS="${K8S_PUBLIC_WAIT_ATTEMPTS:-60}"

get_public_address() {
  local address

  address="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get service \
    "${K8S_PUBLIC_SERVICE}" \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

  if [[ -z "${address}" ]]; then
    address="$(${KUBECTL} --namespace "${K8S_NAMESPACE}" get service \
      "${K8S_PUBLIC_SERVICE}" \
      --output jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  fi

  printf '%s' "${address}"
}

public_address=""
for ((attempt = 1; attempt <= K8S_PUBLIC_WAIT_ATTEMPTS; attempt += 1)); do
  public_address="$(get_public_address)"
  if [[ -n "${public_address}" ]]; then
    break
  fi

  if [[ "${attempt}" -eq 1 ]]; then
    echo "Waiting for the external load balancer address..." >&2
  fi
  sleep 5
done

if [[ -z "${public_address}" ]]; then
  echo "The service ${K8S_NAMESPACE}/${K8S_PUBLIC_SERVICE} has no external address." >&2
  exit 1
fi

public_url="http://${public_address}"

if [[ "${K8S_PUBLIC_CHECK_REQUESTS}" -eq 0 ]]; then
  echo "${public_url}"
  exit 0
fi

http_ready=0
for ((attempt = 1; attempt <= K8S_PUBLIC_WAIT_ATTEMPTS; attempt += 1)); do
  status_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 15 "${public_url}/api/bulletins" 2>/dev/null)" || status_code="000"
  case "${status_code}" in
    2??)
      http_ready=1
      break
      ;;
    *) sleep 5 ;;
  esac
done

if [[ "${http_ready}" -ne 1 ]]; then
  echo "The load balancer did not return a successful response: ${public_url}/api/bulletins" >&2
  exit 1
fi

successful_requests=0
for ((request = 1; request <= K8S_PUBLIC_CHECK_REQUESTS; request += 1)); do
  status_code="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' --connect-timeout 5 --max-time 15 \
    "${public_url}/api/bulletins")" || status_code="000"

  case "${status_code}" in
    2??)
      successful_requests=$((successful_requests + 1))
      ;;
    *)
      echo "Request ${request} failed with HTTP ${status_code}." >&2
      exit 1
      ;;
  esac
done

echo "${successful_requests}/${K8S_PUBLIC_CHECK_REQUESTS} requests succeeded: ${public_url}/api/bulletins"
