#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq "$KUBECTL"

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

SKIP_VERIFY=1 bash "$(dirname "$0")/manifests.sh"

"$KUBECTL" apply -f "$DEPLOY_DIR/hello-world.yaml"

"$KUBECTL" -n "$APP_NAMESPACE" rollout status "deployment/$APP_NAME" \
  --timeout="${ROLLOUT_TIMEOUT:-120s}"

echo "$APP_NAME deployed to namespace $APP_NAMESPACE"
