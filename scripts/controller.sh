#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

HELM="${HELM:-helm}"
FLUX="${FLUX:-flux}"
KIND="${KIND:-kind}"
KIND_CLUSTER="${KIND_CLUSTER:-ocm-controller}"
export KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/controller/kubeconfig}"
export KIND_CLUSTER

OCM_CONTROLLER_CHART_VERSION="0.15.0"
KRO_CHART_VERSION="v0.9.4"
FLUX_VERSION="v2.9.6"

OCM_CONTROLLER_REPO="${OCM_CONTROLLER_REPO:-ghcr.io/lioramilbaum/ocm}"

_install() {
  require "$HELM" "$FLUX" "$KUBECTL"
  "$HELM" upgrade --install ocm-k8s-toolkit \
    oci://ghcr.io/open-component-model/kubernetes/controller/chart \
    --version "$OCM_CONTROLLER_CHART_VERSION" \
    --namespace ocm-k8s-toolkit-system --create-namespace \
    --set fullnameOverride=ocm-k8s-toolkit \
    --wait --timeout 5m
  "$HELM" upgrade --install kro \
    oci://registry.k8s.io/kro/charts/kro \
    --version "$KRO_CHART_VERSION" \
    --namespace kro-system --create-namespace \
    --wait --timeout 5m
  "$FLUX" install --version "$FLUX_VERSION"
  "$FLUX" check
}

_apply() {
  require "$KUBECTL"
  local bootstrap="$ROOT/k8s/controller/bootstrap.yaml"
  local instance="$ROOT/k8s/controller/instance.yaml"
  # Rewrite baseUrl when OCM_CONTROLLER_REPO is overridden from the default
  sed "s|ghcr.io/lioramilbaum/ocm|$OCM_CONTROLLER_REPO|g" "$bootstrap" \
    | "$KUBECTL" apply -f -
  "$KUBECTL" wait --for=condition=Ready \
    repository/application-repository \
    component/application \
    resource/hello-world-rgd \
    --timeout=5m
  "$KUBECTL" wait --for=condition=Ready \
    namespaceddeployer/hello-world \
    --timeout=5m
  # Wait for the RGD to become active (kro)
  "$KUBECTL" wait --for=jsonpath='{.status.state}'=Active \
    resourcegraphdefinition/hello-world \
    --timeout=5m
  # Apply instance with architecture matching the host
  sed "s|architecture: amd64|architecture: $TARGET_ARCH|g" "$instance" \
    | "$KUBECTL" apply -f -
}

_check() {
  require "$KUBECTL"
  "$KUBECTL" wait --for=jsonpath='{.status.state}'=ACTIVE \
    helloworld/hello-world \
    --timeout=10m
  "$KUBECTL" -n hello-world rollout status deployment/hello-world --timeout=5m
  "$KUBECTL" -n hello-world wait pod \
    --for=condition=Ready --selector=app=hello-world --timeout=2m
  "$KUBECTL" -n hello-world exec deploy/hello-world -- \
    wget -qO- http://localhost/ | grep -q Hello
  echo "controller stack deployment verified"
}

cmd="${1:-run}"
case "$cmd" in
  install) _install ;;
  apply)   _apply ;;
  check)   _check ;;
  down)
    require "$KIND"
    "$KIND" delete cluster --name "$KIND_CLUSTER"
    ;;
  run)
    require "$KIND" docker "$HELM" "$FLUX" "$KUBECTL"
    mkdir -p "$(dirname "$KUBECONFIG")"
    cluster_existed=0
    if "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
      cluster_existed=1
    fi
    if [[ "$cluster_existed" -eq 0 ]]; then
      # shellcheck disable=SC2016
      trap '[[ "${KEEP_CLUSTER:-0}" == "1" ]] || "$KIND" delete cluster --name "$KIND_CLUSTER"' EXIT
    fi
    # cluster.sh writes its kubeconfig to E2E_KUBECONFIG; point it at this stack's file
    E2E_KUBECONFIG="$KUBECONFIG" bash "$ROOT/scripts/cluster.sh" up
    _install
    _apply
    _check
    ;;
  *) die "usage: controller.sh [run|install|apply|check|down]" ;;
esac
