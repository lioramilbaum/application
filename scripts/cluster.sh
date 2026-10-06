#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

KIND="${KIND:-kind}"
KIND_CLUSTER="${KIND_CLUSTER:-ocm-application}"
export KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/e2e/kubeconfig}"

cmd="${1:-}"
case "$cmd" in
  up)
    require "$KIND" docker
    mkdir -p "$(dirname "$KUBECONFIG")"
    if "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
      echo "Cluster '$KIND_CLUSTER' already exists; exporting kubeconfig ..."
      "$KIND" export kubeconfig --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG"
    else
      echo "Creating cluster '$KIND_CLUSTER' ..."
      "$KIND" create cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG" --wait 60s
    fi
    ;;
  down)
    require "$KIND"
    "$KIND" delete cluster --name "$KIND_CLUSTER"
    ;;
  *)
    die "usage: cluster.sh up|down"
    ;;
esac
