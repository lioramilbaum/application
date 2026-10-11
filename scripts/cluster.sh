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
    if [[ -n "${KIND_REGISTRY_HOST:-}" ]]; then
      [[ -n "${KIND_REGISTRY_ENDPOINT:-}" ]] || die "KIND_REGISTRY_ENDPOINT must be set when KIND_REGISTRY_HOST is set"
      while IFS= read -r node; do
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/${KIND_REGISTRY_HOST}"
        printf '[host."%s"]\n' "$KIND_REGISTRY_ENDPOINT" | \
          docker exec -i "$node" tee "/etc/containerd/certs.d/${KIND_REGISTRY_HOST}/hosts.toml" > /dev/null
      done < <("$KIND" get nodes --name "$KIND_CLUSTER")
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
