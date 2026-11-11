#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/bootstrap-bundle.sh
source "$(dirname "$0")/bootstrap-bundle.sh"

# Target side of the air-gapped path, run where the cluster is. Every subcommand is offline; the bundle the
# source side wrote online (make package) is the only input. The one outside input is the kind node image, which stands
# in for the site's own cluster (scripts/cluster.sh pins it).
#   cluster    creates the stand-in kind cluster (or reuses it); bootstrap runs it when the cluster is missing
#   bootstrap  prepares the environment: cluster, platform images from the bundle, registry, containerd, controller stack
#   transfer   puts the application component into that registry
#   deploy     applies the application and checks it
#   up         bootstrap, transfer and deploy; leaves everything running
#   down       deletes the cluster and the registry
# docs/bootstrap.md.

HELM="${HELM:-helm}"
KIND="${KIND:-kind}"
export HELM KIND
KIND_CLUSTER="${KIND_CLUSTER:-ocm-bootstrap}"
export KIND_CLUSTER
export KUBECONFIG="${E2E_KUBECONFIG:-$BUILD_DIR/bootstrap-e2e/kubeconfig}"
BOOTSTRAP_REGISTRY_NAME="${BOOTSTRAP_REGISTRY_NAME:-ocm-bootstrap-registry}"
# Host-side tools in bootstrap, transfer and deploy send HTTP(S) through this proxy. Port 9 has no listener, so a
# request to the internet fails at once.
BOOTSTRAP_OFFLINE_PROXY="http://127.0.0.1:9"

registry_ref() { echo "oci::http://$1:5000/ocm//$ROOT_COMPONENT:$VERSION"; }

# _offline_proxy [REGISTRY_IP]: exports the proxy for the host-side tools that the offline subcommands run. NO_PROXY keeps
# localhost, the API server named in the kubeconfig and the registry reachable. Go clients (ocm, helm, kubectl)
# never proxy loopback addresses by themselves, and curl honours NO_PROXY for IP addresses. An IPv6 API server
# ([fd00::1]:6443) goes into NO_PROXY without its brackets, the form Go and curl match against.
_offline_proxy() {
  local api="" no
  if [[ -f "$KUBECONFIG" ]]; then
    api="$(awk '/^[[:space:]]*server:/ {
      h = $2; gsub(/["\047]/, "", h); sub(/^[a-z]*:\/\//, "", h)
      if (h ~ /^\[/) { sub(/^\[/, "", h); sub(/\].*/, "", h) } else sub(/[:\/].*/, "", h)
      print h; exit
    }' "$KUBECONFIG")"
  fi
  no="localhost,127.0.0.1${api:+,$api}${1:+,$1}"
  export HTTP_PROXY="$BOOTSTRAP_OFFLINE_PROXY" HTTPS_PROXY="$BOOTSTRAP_OFFLINE_PROXY" \
    http_proxy="$BOOTSTRAP_OFFLINE_PROXY" https_proxy="$BOOTSTRAP_OFFLINE_PROXY" \
    NO_PROXY="$no" no_proxy="$no"
}

_wait_registry() {
  local _
  for _ in $(seq 1 40); do
    curl -fsS -o /dev/null "http://$1:5000/v2/" 2>/dev/null && return 0
    sleep 0.25
  done
  die "registry not reachable at http://$1:5000"
}

# Prints the registry's address on the kind network, or nothing when it is not running
_registry_ip() {
  docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$BOOTSTRAP_REGISTRY_NAME" 2>/dev/null || true
}

# _require_registry: sets REGISTRY_IP to the registry bootstrap started; dies when bootstrap has not run
_require_registry() {
  REGISTRY_IP="$(_registry_ip)"
  [[ -n "$REGISTRY_IP" ]] || \
    die "registry $BOOTSTRAP_REGISTRY_NAME is not running on the kind network (bootstrap the target first: make target-bootstrap)"
}

# _arch MACHINE: the platform architecture name of a uname -m or docker info machine name
_arch() {
  case "$1" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             echo "$1" ;;
  esac
}

# _archive_has_name ARCHIVE NAME: true when the archive's index.json names an image NAME
_archive_has_name() {
  tar -xOf "$1" index.json 2>/dev/null \
    | jq -e --arg n "$2" 'any(.manifests[]?; .annotations["io.containerd.image.name"] == $n)' >/dev/null 2>&1
}

# _check_node_archive REF: the archive for REF names the image the way a node looks it up: by digest when REF
# carries one, by tag when it has one
_check_node_archive() {
  local ref="$1" archive repo name="${1%%@*}"
  archive="$BOOTSTRAP_BUNDLE_DIR/$(_image_archive "$ref")"
  repo="$(_image_repo "$ref")"
  if [[ "$ref" == *@* ]]; then
    _archive_has_name "$archive" "$repo@${ref##*@}" \
      || die "$archive does not hold $repo@${ref##*@} (rebuild the bundle with make package)"
  fi
  if [[ "${name##*/}" == *:* ]]; then
    _archive_has_name "$archive" "$repo:${name##*:}" \
      || die "$archive does not hold $repo:${name##*:} (rebuild the bundle with make package)"
  fi
  return 0
}

# _check_registry_archive ARCH: images/registry.tar holds the pinned index blob, that blob lists a linux/ARCH
# manifest, and the archive tags that manifest $BOOTSTRAP_REGISTRY_LOCAL_REF-ARCH for both Docker image stores: as
# docker.io/<ref> in index.json (containerd store) and as <ref> in manifest.json (classic store), with that
# manifest's config. Prints "<manifest> <config>".
_check_registry_archive() {
  local arch="$1" archive="$BOOTSTRAP_BUNDLE_DIR/images/registry.tar" pin work m config normalized
  pin="${BOOTSTRAP_REGISTRY_IMAGE##*@sha256:}"
  work="$BUILD_DIR/target-registry-archive"
  rm -rf "$work"
  mkdir -p "$work"
  tar -xf "$archive" -C "$work" index.json manifest.json "blobs/sha256/$pin" 2>/dev/null \
    || die "$archive does not hold the pinned registry index sha256:$pin (rebuild the bundle with make package)"
  [[ "$(sha256 "$work/blobs/sha256/$pin")" == "$pin" ]] \
    || die "$archive: the registry index does not match its pin sha256:$pin (rebuild the bundle with make package)"
  m="$(jq -r --arg a "$arch" \
    'first(.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest) // empty' \
    "$work/blobs/sha256/$pin")"
  [[ -n "$m" ]] || die "the pinned registry image has no linux/$arch manifest"
  tar -xf "$archive" -C "$work" "blobs/sha256/${m#sha256:}" 2>/dev/null \
    || die "$archive does not hold the linux/$arch registry manifest $m (rebuild the bundle with make package)"
  [[ "sha256:$(sha256 "$work/blobs/sha256/${m#sha256:}")" == "$m" ]] \
    || die "$archive: the linux/$arch registry manifest does not match $m"
  normalized="$(_image_repo "$BOOTSTRAP_REGISTRY_LOCAL_REF"):${BOOTSTRAP_REGISTRY_LOCAL_REF##*:}-$arch"
  jq -e --arg d "$m" --arg n "$normalized" \
    'any(.manifests[]; .digest == $d and .annotations["io.containerd.image.name"] == $n)' "$work/index.json" >/dev/null \
    || die "$archive does not tag $m as $normalized (rebuild the bundle with make package)"
  config="$(jq -r '.config.digest' "$work/blobs/sha256/${m#sha256:}")"
  jq -e --arg c "blobs/${config/://}" --arg n "$BOOTSTRAP_REGISTRY_LOCAL_REF-$arch" \
    'any(.[]; .Config == $c and (.RepoTags | index($n)))' "$work/manifest.json" >/dev/null \
    || die "$archive does not tag the linux/$arch config $config as $BOOTSTRAP_REGISTRY_LOCAL_REF-$arch in manifest.json (rebuild the bundle with make package)"
  rm -rf "$work"
  echo "$m $config"
}

# _import_image NODE ARCH REF: loads the archive for REF into the node's containerd, keeping only linux/ARCH
_import_image() {
  docker exec -i "$1" ctr --namespace=k8s.io images import --platform "linux/$2" - \
    < "$BOOTSTRAP_BUNDLE_DIR/$(_image_archive "$3")" >/dev/null
}

# cluster: the stand-in for the site's own Kubernetes cluster, from the pinned kind node image (scripts/cluster.sh).
# Reuses the cluster when it exists. config_path makes containerd read /etc/containerd/certs.d, where cluster.sh
# writes the registry hosts.toml. kind copies proxy variables into the nodes, so it runs without them. In CI this
# runs before the egress block: the kind node entrypoint resolves host.docker.internal, and Docker's embedded DNS
# forwards that query upstream. bootstrap calls it too, so a target without a cluster gets one.
_cluster() {
  require "$KIND" docker
  local cfg="$BUILD_DIR/bootstrap-kind.yaml"
  mkdir -p "$BUILD_DIR"
  cat > "$cfg" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy \
    E2E_KUBECONFIG="$KUBECONFIG" KIND_CONFIG="$cfg" bash "$ROOT/scripts/cluster.sh" up
}

# bootstrap: offline. Prepares the environment the application is deployed into: the cluster, the platform images
# from the bundle, the registry on the kind network, containerd pointed at it, and the controller stack (OCM
# controller, kro, Flux and the controller RBAC). Nothing of the application is transferred or applied.
_bootstrap() {
  require "$KIND" "$HELM" "$KUBECTL" docker curl jq tar
  local missing ref host_arch registry_tag registry_digests load_out id node arch ip
  local -a images nodes
  _offline_proxy

  # 1. The bundle is complete, including an archive per node image
  missing="$(_missing_bundle_file)"
  [[ -z "$missing" ]] || die "bootstrap bundle is incomplete: $BOOTSTRAP_BUNDLE_DIR/$missing is missing (build it with: make package)"

  # 2. Each archive names its image, and the registry archive matches its pin. Checked before anything is created.
  mapfile -t images < <(awk 'NF' "$BOOTSTRAP_BUNDLE_DIR/images.txt")
  for ref in "${images[@]}"; do
    _check_node_archive "$ref"
  done
  host_arch="$(_arch "$(docker info -f '{{.Architecture}}')")"
  registry_tag="$BOOTSTRAP_REGISTRY_LOCAL_REF-$host_arch"
  registry_digests="$(_check_registry_archive "$host_arch")"

  # 3. The cluster, unless `cluster` created it already
  _cluster

  # 4. The registry image on the host, by the tag of the host's platform. Its ID is the manifest (containerd image
  # store) or the config (classic image store) checked against the pin above.
  load_out="$(docker load -i "$BOOTSTRAP_BUNDLE_DIR/images/registry.tar" 2>&1)" \
    || die "docker load of images/registry.tar failed: $load_out"
  id="$(docker image inspect -f '{{.Id}}' "$registry_tag" 2>/dev/null)" \
    || die "loading images/registry.tar gave no image $registry_tag; docker load said: $load_out"
  [[ " $registry_digests " == *" $id "* ]] || die "image $registry_tag is $id, not the pinned registry image ($registry_digests)"

  # 5. The node images, into every node's containerd, for that node's platform
  mapfile -t nodes < <("$KIND" get nodes --name "$KIND_CLUSTER")
  for node in "${nodes[@]}"; do
    arch="$(_arch "$(docker exec "$node" uname -m)")"
    for ref in "${images[@]}"; do
      _import_image "$node" "$arch" "$ref" \
        || die "importing $(_image_archive "$ref") into node $node failed (rebuild the bundle with make package)"
    done
  done

  # 6. Every node resolves every image the way kubelet will. A miss is imported once more, then fails. The retry
  # may fail too: the lookup after it reports the image that is missing.
  for node in "${nodes[@]}"; do
    for ref in "${images[@]}"; do
      docker exec "$node" crictl inspecti "$ref" >/dev/null 2>&1 && continue
      _import_image "$node" "$(_arch "$(docker exec "$node" uname -m)")" "$ref" || true
      docker exec "$node" crictl inspecti "$ref" >/dev/null 2>&1 \
        || die "image $ref is not on node $node after importing $(_image_archive "$ref") (rebuild the bundle with make package)"
    done
  done

  # 7. Registry on the kind network. The nodes reach it; it publishes no port to the host.
  docker rm -f "$BOOTSTRAP_REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$BOOTSTRAP_REGISTRY_NAME" --network kind --pull never "$registry_tag" >/dev/null \
    || die "could not start $BOOTSTRAP_REGISTRY_NAME from $registry_tag"
  ip="$(_registry_ip)"
  [[ -n "$ip" ]] || die "$BOOTSTRAP_REGISTRY_NAME has no address on the kind network"
  _offline_proxy "$ip"
  _wait_registry "$ip"

  # 8. containerd on every node pulls <ip>:5000 from the registry over plain HTTP
  E2E_KUBECONFIG="$KUBECONFIG" KIND_REGISTRY_HOST="$ip:5000" KIND_REGISTRY_ENDPOINT="http://$ip:5000" \
    bash "$ROOT/scripts/cluster.sh" up

  # 9. The controller stack from the bundle charts and Flux manifests (controller.sh install also applies the RBAC)
  OCM_CONTROLLER_CHART="$BOOTSTRAP_BUNDLE_DIR/charts/ocm-k8s-toolkit.tgz" \
    KRO_CHART="$BOOTSTRAP_BUNDLE_DIR/charts/kro.tgz" \
    FLUX_MANIFESTS="$BOOTSTRAP_BUNDLE_DIR/flux/install.yaml" \
    E2E_KUBECONFIG="$KUBECONFIG" HELM="$HELM" \
    bash "$ROOT/scripts/controller.sh" install
  echo "bootstrap complete: registry at $ip:5000, controller stack installed on $KIND_CLUSTER"
}

# transfer: offline. Puts the application component from the bundle into the registry bootstrap started.
_transfer() {
  require "$OCM" docker jq curl
  local missing verify_cfg non_local reg
  _offline_proxy

  # 1. The bundle is complete
  missing="$(_missing_bundle_file)"
  [[ -z "$missing" ]] || die "bootstrap bundle is incomplete: $BOOTSTRAP_BUNDLE_DIR/$missing is missing (build it with: make package)"

  # 2. The bundle CTF is signed by the bundled public key
  verify_cfg="$BOOTSTRAP_VERIFY_CONFIG"
  _verify_config "$BOOTSTRAP_BUNDLE_DIR/public.pem" "$verify_cfg"
  "$OCM" verify cv --config "$verify_cfg" --signature default "$(bundle_ref)" </dev/null >/dev/null \
    || die "bundle signature does not verify against $BOOTSTRAP_BUNDLE_DIR/public.pem"

  # 3. Self-containment: every resource must be a local blob. Anything fetched from outside the
  # bundle would be unreachable from the air-gapped cluster.
  non_local="$("$OCM" get cv "$(bundle_ref)" --recursive -o json </dev/null \
    | jq -r '[.[].component.resources[]? | select((.access.type // "") | ascii_downcase | startswith("localblob") | not) | .name] | unique | join(", ")')"
  [[ -z "$non_local" ]] || \
    die "bundle is not self-contained; these resources live outside it: $non_local (rebuild the bundle with make package)"

  # 4. The registry bootstrap started
  _require_registry
  _offline_proxy "$REGISTRY_IP"
  _wait_registry "$REGISTRY_IP"

  # 5. Publish the bundle CTF to the registry. publish.sh inlines the local blobs as OCI artifacts;
  # transfer.ocmconfig gives each hello-world-image architecture its own tag, so variants do not overwrite each other.
  OCM_COMPONENT_REPO="ctf::$BOOTSTRAP_BUNDLE_DIR/ctf" OCM_REPO="oci::http://$REGISTRY_IP:5000/ocm" \
    TRANSFER_CONFIG="$ROOT/transfer.ocmconfig" \
    bash "$ROOT/scripts/publish.sh"

  # 6. Verify the registry copy
  reg="$(registry_ref "$REGISTRY_IP")"
  "$OCM" verify cv --config "$verify_cfg" --signature default "$reg" </dev/null >/dev/null \
    || die "registry copy does not verify against $BOOTSTRAP_BUNDLE_DIR/public.pem"
  echo "transfer verified: $ROOT_COMPONENT:$VERSION in $REGISTRY_IP:5000/ocm"
}

# deploy: offline. Applies the application from the registry copy and checks it. Only the application: the
# environment is bootstrap's, and the component must already be in the registry (transfer).
_deploy() {
  require "$OCM" "$KUBECTL" docker jq curl
  local verify_cfg reg work name desc actual img
  local -a running
  _offline_proxy

  # 1. The key that verifies the component
  [[ -f "$BOOTSTRAP_BUNDLE_DIR/public.pem" ]] || \
    die "bootstrap bundle is incomplete: $BOOTSTRAP_BUNDLE_DIR/public.pem is missing (build it with: make package)"

  # 2. The registry bootstrap started, holding the component transfer put there
  _require_registry
  _offline_proxy "$REGISTRY_IP"
  _wait_registry "$REGISTRY_IP"
  reg="$(registry_ref "$REGISTRY_IP")"
  "$OCM" get cv "$reg" -o json </dev/null >/dev/null 2>&1 || \
    die "component $ROOT_COMPONENT:$VERSION is not in the registry at $REGISTRY_IP:5000 (transfer it first: make target-transfer)"

  # 3. The registry copy is still signed by the bundled key: its descriptor digests are trusted below
  verify_cfg="$BOOTSTRAP_VERIFY_CONFIG"
  _verify_config "$BOOTSTRAP_BUNDLE_DIR/public.pem" "$verify_cfg"
  "$OCM" verify cv --config "$verify_cfg" --signature default "$reg" </dev/null >/dev/null \
    || die "registry copy does not verify against $BOOTSTRAP_BUNDLE_DIR/public.pem"

  # 4. Take the controller manifests from the registry copy and check each against its descriptor digest
  work="$BUILD_DIR/target-deploy"
  rm -rf "$work"
  mkdir -p "$work"
  for name in hello-world-deploy hello-world-instance; do
    "$OCM" download resource "$reg" --identity "name=$name" --output "$work/$name.yaml" </dev/null >/dev/null
    desc="$("$OCM" get cv "$reg" -o json </dev/null \
      | jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .digest.value')"
    actual="$(sha256 "$work/$name.yaml")"
    [[ -n "$desc" && "$actual" == "$desc" ]] || \
      die "$name does not match its descriptor digest (descriptor: ${desc:-none}, downloaded: $actual)"
  done

  # 5. Apply the component's deploy manifest and instance, with the controller pointed at the registry
  OCM_CONTROLLER_REPO="http://$REGISTRY_IP:5000/ocm" OCM_CONTROLLER_INSECURE=true \
    DEPLOY_FILE="$work/hello-world-deploy.yaml" \
    INSTANCE_FILE="$work/hello-world-instance.yaml" \
    E2E_KUBECONFIG="$KUBECONFIG" \
    bash "$ROOT/scripts/controller.sh" apply

  # 6. The instance answers, and the pods run images from the registry copy
  E2E_KUBECONFIG="$KUBECONFIG" bash "$ROOT/scripts/controller.sh" check
  read -r -a running <<< "$("$KUBECTL" -n hello-world get pods \
    -l app.kubernetes.io/name=hello-world -o jsonpath='{.items[*].spec.containers[*].image}')"
  [[ ${#running[@]} -gt 0 ]] || die "no hello-world pods found"
  for img in "${running[@]}"; do
    [[ "$img" == "$REGISTRY_IP:5000/"* ]] || die "pod runs $img, not an image from the bootstrap registry $REGISTRY_IP:5000"
  done
  echo "deploy verified: pods run images from $REGISTRY_IP:5000"
}

# up: bootstrap, transfer and deploy. Leaves the cluster and the registry running; remove them with down.
_up() {
  _bootstrap
  _transfer
  _deploy
}

_down() {
  require "$KIND" docker
  "$KIND" delete cluster --name "$KIND_CLUSTER"
  docker rm -f "$BOOTSTRAP_REGISTRY_NAME" >/dev/null 2>&1 || true
}

cmd="${1:-}"
case "$cmd" in
  cluster)   _cluster ;;
  bootstrap) _bootstrap ;;
  transfer)  _transfer ;;
  deploy)    _deploy ;;
  up)        _up ;;
  down)      _down ;;
  *) die "usage: targetctl.sh cluster|bootstrap|transfer|deploy|up|down" ;;
esac
