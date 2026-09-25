#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_DIR}/../scripts/preflight.sh"

az() {
  if [[ "$*" == "rest --method get --url /providers/Microsoft.Authorization/${expected_resource_type}/fixture-policy?api-version=2023-04-01 --output json" ]]; then
    [[ -n "${versions_response}" ]] || { printf '%s\n' 'Unexpected versions request' >&2; return 99; }
    if [[ "${versions_exit_code}" != 0 ]]; then
      printf '%s\n' 'AuthorizationFailed: fixture denied' >&2
      return "${versions_exit_code}"
    fi
    printf '%s\n' "${versions_response}"
    return 0
  fi
  [[ "$*" == "policy ${expected_command} show --name fixture-policy --output json" ]] \
    || { printf 'Unexpected Azure command: %s\n' "$*" >&2; return 99; }
  if [[ "${mock_exit_code}" != 0 ]]; then
    printf '%s\n' 'AuthorizationFailed: fixture denied' >&2
    return "${mock_exit_code}"
  fi
  printf '%s\n' "${mock_response}"
}

for kind in policyDefinition policySetDefinition; do
  expected_command='definition'
  expected_resource_type='policyDefinitions'
  [[ "${kind}" != policySetDefinition ]] || expected_command='set-definition'
  [[ "${kind}" != policySetDefinition ]] || expected_resource_type='policySetDefinitions'
  while IFS= read -r fixture; do
    name="$(jq -r '.name' <<<"${fixture}")"
    mock_response="$(jq -r '.response' <<<"${fixture}")"
    mock_exit_code="$(jq -r '.exitCode // 0' <<<"${fixture}")"
    versions_response="$(jq -r '.versionsResponse // empty' <<<"${fixture}")"
    versions_exit_code="$(jq -r '.versionsExitCode // 0' <<<"${fixture}")"
    expected="$(jq -r '.expected' <<<"${fixture}")"
    if output="$(check_policy_version "${kind}" fixture-policy 1 2>&1)"; then
      [[ -z "${expected}" ]] || fail "${kind}/${name}: expected failure, got success."
    else
      [[ -n "${expected}" && "${output}" == *"${expected}"* ]] \
        || fail "${kind}/${name}: unexpected failure: ${output}"
      if [[ "${mock_exit_code}" != 0 || "${versions_exit_code}" != 0 ]]; then
        [[ "${output}" == *'AuthorizationFailed: fixture denied'* ]] \
          || fail "${kind}/${name}: Azure CLI diagnostic was lost."
      fi
    fi
  done < <(jq -c '.[]' "${TEST_DIR}/fixtures/preflight-policy-version-cases.json")
done
printf '%s\n' 'Built-in policy version fixtures passed (Bash).'
