#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

KIND="${KIND:-kind}"
KIND_CLUSTER="${KIND_CLUSTER:-ocm-application}"
export KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/e2e/kubeconfig}"
# Node image for every kind cluster, pinned by digest. It must be one the pinned kind version supports: the release
# notes of KIND_VERSION (.devcontainer/Dockerfile) list them. CI pulls it before the egress block (cluster.sh node-image).
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"

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
      create_args=(create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE" --kubeconfig "$KUBECONFIG" --wait 60s)
      # KIND_CONFIG is read at creation only (scripts/targetctl.sh sets containerd options this way)
      [[ -z "${KIND_CONFIG:-}" ]] || create_args+=(--config "$KIND_CONFIG")
      "$KIND" "${create_args[@]}"
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
  node-image)
    echo "$KIND_NODE_IMAGE"
    ;;
  down)
    require "$KIND"
    "$KIND" delete cluster --name "$KIND_CLUSTER"
    ;;
  *)
    die "usage: cluster.sh up|down|node-image"
    ;;
esac
