#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

KIND="${KIND:-$ROOT/bin/kind}"
KIND_CLUSTER="${KIND_CLUSTER:-ocm-application}"
export KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/e2e/kubeconfig}"

require "$OCM" "$KUBECTL" "$KIND" docker

mkdir -p "$(dirname "$KUBECONFIG")"

if ! "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  "$KIND" create cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG" --wait 60s
fi

if [[ "${KEEP_CLUSTER:-0}" != "1" ]]; then
  trap '"$KIND" delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true' EXIT
fi

bash "$(dirname "$0")/deploy.sh"

"$KUBECTL" -n "$APP_NAMESPACE" wait pod \
  --selector "app.kubernetes.io/name=$APP_NAME" \
  --for condition=Ready \
  --timeout=60s

result="$("$KUBECTL" -n "$APP_NAMESPACE" exec "deploy/$APP_NAME" -- wget -qO- http://localhost/)"
echo "$result" | grep -q "Hello" || die "HelloWorld response not found (got: $result)"

echo "$APP_NAME e2e: pod ready, response contains 'Hello'"
