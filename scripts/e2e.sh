#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

KIND="${KIND:-kind}"
KIND_CLUSTER="${KIND_CLUSTER:-ocm-application}"
export KIND KIND_CLUSTER KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/e2e/kubeconfig}"
SCRIPT_DIR="$(dirname "$0")"

require "$OCM" "$KUBECTL" "$KIND" docker

created=0
if ! "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  created=1
fi

bash "$SCRIPT_DIR/cluster.sh" up

if [[ "$created" -eq 1 && "${KEEP_CLUSTER:-0}" != "1" ]]; then
  trap 'bash "$SCRIPT_DIR/cluster.sh" down >/dev/null 2>&1 || true' EXIT
fi

bash "$(dirname "$0")/deploy.sh"

"$KUBECTL" -n "$APP_NAMESPACE" wait pod \
  --selector "app.kubernetes.io/name=$APP_NAME" \
  --for condition=Ready \
  --timeout=60s

result="$("$KUBECTL" -n "$APP_NAMESPACE" exec "deploy/$APP_NAME" -- wget -qO- http://localhost/)"
echo "$result" | grep -q "Hello" || die "HelloWorld response not found (got: $result)"

echo "$APP_NAME e2e: pod ready, response contains 'Hello'"
