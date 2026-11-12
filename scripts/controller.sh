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

OCM_CONTROLLER_CHART_VERSION="0.23.0"
# Renovate tracks kro release tags (v0.9.4); the chart is published as 0.9.4, so the v is dropped for helm
KRO_CHART_VERSION="v0.9.4"
FLUX_VERSION="v2.10.0"

OCM_CONTROLLER_REPO="${OCM_CONTROLLER_REPO:-ghcr.io/lioramilbaum/ocm}"
# Chart registry references. A local .tgz path installs offline (scripts/sourcectl.sh reads these two constants).
OCM_CONTROLLER_CHART_REF="oci://ghcr.io/open-component-model/kubernetes/controller/chart"
KRO_CHART_REF="oci://registry.k8s.io/kro/charts/kro"
OCM_CONTROLLER_CHART="${OCM_CONTROLLER_CHART:-$OCM_CONTROLLER_CHART_REF}"
KRO_CHART="${KRO_CHART:-$KRO_CHART_REF}"
# FLUX_MANIFESTS: a Flux install manifest applied with kubectl instead of `flux install`.
FLUX_MANIFESTS="${FLUX_MANIFESTS:-}"
DEPLOY_FILE="${DEPLOY_FILE:-$ROOT/k8s/controller/deploy.yaml}"
INSTANCE_FILE="${INSTANCE_FILE:-$ROOT/k8s/controller/instance.yaml}"
# Controller RBAC, applied by install on both the online and the air-gapped path
CONTROLLER_RBAC_FILE="$ROOT/k8s/controller/rbac.yaml"
# OCM_CONTROLLER_INSECURE=true sets insecure: true on the HelloWorld instance (plain-HTTP registry).
OCM_CONTROLLER_INSECURE="${OCM_CONTROLLER_INSECURE:-false}"

_install() {
  require "$HELM" "$KUBECTL"
  # A local chart file carries its own version, so --version is only passed for registry charts.
  local ocm_version=() kro_version=()
  [[ -f "$OCM_CONTROLLER_CHART" ]] || ocm_version=(--version "$OCM_CONTROLLER_CHART_VERSION")
  [[ -f "$KRO_CHART" ]] || kro_version=(--version "${KRO_CHART_VERSION#v}")
  "$HELM" upgrade --install ocm-k8s-toolkit \
    "$OCM_CONTROLLER_CHART" \
    ${ocm_version[@]+"${ocm_version[@]}"} \
    --namespace ocm-k8s-toolkit-system --create-namespace \
    --set fullnameOverride=ocm-k8s-toolkit \
    --wait --timeout 5m
  # Environment setup: lets the controller's service account read the RGDs it deploys
  "$KUBECTL" apply -f "$CONTROLLER_RBAC_FILE"
  "$HELM" upgrade --install kro \
    "$KRO_CHART" \
    ${kro_version[@]+"${kro_version[@]}"} \
    --namespace kro-system --create-namespace \
    --wait --timeout 5m
  if [[ -n "$FLUX_MANIFESTS" ]]; then
    [[ -f "$FLUX_MANIFESTS" ]] || die "FLUX_MANIFESTS not found: $FLUX_MANIFESTS"
    "$KUBECTL" apply -f "$FLUX_MANIFESTS"
    "$KUBECTL" -n flux-system wait --for=condition=Available deployment --all --timeout=5m
  else
    require "$FLUX"
    "$FLUX" install --version "$FLUX_VERSION"
    "$FLUX" check
  fi
}

# _render DIR SOURCE PATCHES: copies SOURCE into DIR, applies PATCHES (a JSON list of
# kustomize patches) with kubectl kustomize and prints the result. A failing test
# operation makes kustomize exit non-zero, so nothing reaches kubectl apply.
_render() {
  local dir="$1" src="$2" patches="$3" base
  [[ -f "$src" ]] || die "manifest not found: $src"
  base="$(basename "$src")"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$src" "$dir/$base"
  jq -n --arg res "$base" --argjson patches "$patches" '{
    apiVersion: "kustomize.config.k8s.io/v1beta1",
    kind: "Kustomization",
    resources: [$res],
    patches: $patches
  }' > "$dir/kustomization.yaml"
  "$KUBECTL" kustomize "$dir"
}

# _assert_rendered RENDERED FILE KIND NAME LINE: dies unless exactly one KIND named NAME in RENDERED has LINE
# (a field such as "baseUrl: x", without its indentation). kustomize renders a file unchanged when a patch
# target matches nothing, so the patch tests alone do not catch a renamed object.
_assert_rendered() {
  local rendered="$1" file="$2" kind="$3" name="$4" line="$5" hits
  # The values reach awk through ENVIRON, not -v: awk -v expands backslash escapes, so a value such as
  # a\tb would be compared as a<TAB>b.
  hits="$(printf '%s\n' "$rendered" | K="$kind" N="$name" WANT="$line" awk '
    function close_doc() {
      if (kind == k && name == n && hit) count++
      kind = ""; name = ""; top = ""; hit = 0
    }
    BEGIN { count = 0; k = ENVIRON["K"]; n = ENVIRON["N"]; want = ENVIRON["WANT"] }
    /^---/ { close_doc(); next }
    /^[A-Za-z]/ { top = $0; sub(/:.*/, "", top); if (top == "kind") kind = $2; next }
    top == "metadata" && /^  name: / { name = $2; next }
    { t = $0; sub(/^[ \t]+/, "", t); if (t == want) hit = 1 }
    END { close_doc(); print count + 0 }
  ')"
  [[ "$hits" == 1 ]] || \
    die "$file does not render $kind $name with '$line': its patch target matched nothing, or the file no longer carries the shipped values (see docs/controller.md)"
}

_apply() {
  require "$KUBECTL" jq
  local render="$BUILD_DIR/controller/render" insecure_ops='[]'
  local deploy_patches instance_patches deploy_rendered instance_rendered
  [[ "$OCM_CONTROLLER_INSECURE" == true || "$OCM_CONTROLLER_INSECURE" == false ]] || \
    die "OCM_CONTROLLER_INSECURE must be true or false (got: $OCM_CONTROLLER_INSECURE)"
  if [[ "$OCM_CONTROLLER_INSECURE" == true ]]; then
    insecure_ops='[{"op":"add","path":"/spec/insecure","value":true}]'
  fi
  # Each patch tests the shipped value before it replaces it, so a manifest that drifted
  # from the defaults fails the render instead of being applied unchanged.
  deploy_patches="$(jq -cn --arg repo "$OCM_CONTROLLER_REPO" '[{
    target: {kind: "Repository", name: "application-repository"},
    patch: ([
      {op: "test", path: "/spec/repositorySpec/baseUrl", value: "ghcr.io/lioramilbaum/ocm"},
      {op: "replace", path: "/spec/repositorySpec/baseUrl", value: $repo}
    ] | tojson)
  }]')"
  instance_patches="$(jq -cn --arg arch "$TARGET_ARCH" --argjson extra "$insecure_ops" '[{
    target: {kind: "HelloWorld", name: "hello-world"},
    patch: ([
      {op: "test", path: "/spec/architecture", value: "amd64"},
      {op: "replace", path: "/spec/architecture", value: $arch}
    ] + $extra | tojson)
  }]')"

  # Both files are rendered and checked before anything is applied, so a bad instance cannot follow an applied deploy manifest.
  deploy_rendered="$(_render "$render/deploy" "$DEPLOY_FILE" "$deploy_patches")"
  _assert_rendered "$deploy_rendered" "$DEPLOY_FILE" Repository application-repository "baseUrl: $OCM_CONTROLLER_REPO"
  instance_rendered="$(_render "$render/instance" "$INSTANCE_FILE" "$instance_patches")"
  _assert_rendered "$instance_rendered" "$INSTANCE_FILE" HelloWorld hello-world "architecture: $TARGET_ARCH"
  if [[ "$OCM_CONTROLLER_INSECURE" == true ]]; then
    _assert_rendered "$instance_rendered" "$INSTANCE_FILE" HelloWorld hello-world "insecure: true"
  fi

  printf '%s\n' "$deploy_rendered" | "$KUBECTL" apply -f -
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
  printf '%s\n' "$instance_rendered" | "$KUBECTL" apply -f -
}

_check() {
  require "$KUBECTL"
  "$KUBECTL" wait --for=jsonpath='{.status.state}'=ACTIVE \
    helloworld/hello-world \
    --timeout=10m
  # ACTIVE can be reported before Flux has created the namespace; rollout status does not wait for that
  "$KUBECTL" -n hello-world wait --for=create deployment/hello-world --timeout=5m
  "$KUBECTL" -n hello-world rollout status deployment/hello-world --timeout=5m
  "$KUBECTL" -n hello-world wait pod \
    --for=condition=Ready --selector=app.kubernetes.io/name=hello-world --timeout=2m
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
