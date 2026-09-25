#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${TEMP_DIR}/scripts" "${TEMP_DIR}/bin"
cp "${PROJECT_DIR}/scripts/deploy.sh" "${PROJECT_DIR}/scripts/what-if.sh" "${TEMP_DIR}/scripts/"
cat > "${TEMP_DIR}/scripts/preflight.sh" <<'EOF'
#!/usr/bin/env bash
printf 'preflight\n' >> "${ESLZ_WORKFLOW_LOG}"
exit "${PREFLIGHT_EXIT}"
EOF
cat > "${TEMP_DIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ESLZ_WORKFLOW_LOG}"
case "${3:-}" in
  what-if) exit "${PREVIEW_EXIT}" ;;
  create) exit "${CREATE_EXIT}" ;;
  *) printf 'Unexpected Azure command\n' >&2; exit 99 ;;
esac
EOF
chmod +x "${TEMP_DIR}/scripts/"*.sh "${TEMP_DIR}/bin/az"
cat > "${TEMP_DIR}/parameters.json" <<'EOF'
{"parameters":{"namePrefix":{"value":"workflow-demo"},"connectivitySubscriptionId":{"value":"connectivity-fixture"},"workloadSubscriptionId":{"value":"workload-fixture"},"deploymentLocation":{"value":"eastus"}}}
EOF
export PATH="${TEMP_DIR}/bin:${PATH}"
export ESLZ_WORKFLOW_LOG="${TEMP_DIR}/calls.log"

while IFS='|' read -r name script confirmation input preflight preview create expected events; do
  export ESLZ_DEPLOY_CONFIRMATION="${confirmation}"
  export PREFLIGHT_EXIT="${preflight}" PREVIEW_EXIT="${preview}" CREATE_EXIT="${create}"
  : > "${ESLZ_WORKFLOW_LOG}"
  status=0
  printf '%s\n' "${input}" | bash "${TEMP_DIR}/scripts/${script}.sh" "${TEMP_DIR}/parameters.json" > "${TEMP_DIR}/output.log" 2>&1 || status=$?
  if [[ "${status}" != "${expected}" ]]; then
    cat "${TEMP_DIR}/output.log" >&2
    printf 'ERROR: %s returned %s, expected %s.\n' "${name}" "${status}" "${expected}" >&2
    exit 1
  fi
  actual="$(sed -E 's/^deployment tenant ([^ ]+).*/\1/' "${ESLZ_WORKFLOW_LOG}" | paste -sd, -)"
  [[ "${actual}" == "${events}" ]] || {
    printf 'ERROR: %s executed %s, expected %s.\n' "${name}" "${actual}" "${events}" >&2
    exit 1
  }
  if [[ "${events}" == *what-if* ]]; then
    grep '^deployment tenant what-if ' "${ESLZ_WORKFLOW_LOG}" |
      grep -F -- '--result-format FullResourcePayloads --exclude-change-types NoChange' >/dev/null
  fi
done <<'EOF'
standalone-preview|what-if||unused|0|0|0|0|preflight,what-if
locked|deploy||workflow-demo|0|0|0|2|preflight,what-if
mismatch|deploy|DEPLOY-ESLZ-DEMO|wrong-root|0|0|0|2|preflight,what-if
confirmed|deploy|DEPLOY-ESLZ-DEMO|workflow-demo|0|0|0|0|preflight,what-if,create
preflight-failure|deploy|DEPLOY-ESLZ-DEMO|workflow-demo|17|0|0|17|preflight
preview-failure|deploy|DEPLOY-ESLZ-DEMO|workflow-demo|0|18|0|18|preflight,what-if
create-failure|deploy|DEPLOY-ESLZ-DEMO|workflow-demo|0|0|19|19|preflight,what-if,create
EOF
printf 'Bash deploy workflow fixtures passed (single preflight, preview detail, confirmations, failure propagation).\n'
