#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# Set up golden directory for testing
GOLDEN_DIR="${GOLDEN_DIR:-$ROOT/.test-golden}"

# OCM >= 0.19.0 is needed for --constraint and versioning schemes.
VERSIONS_OCM="${VERSIONS_OCM:-$OCM}"
# OCM >= 0.19.0 is needed for checksum.http.config (Wget/v1 integrity checks).
WGET_OCM="${WGET_OCM:-$OCM}"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  # shellcheck disable=SC2030
  if (set -euo pipefail; export BUILD_DIR="$tmp" CTF="$tmp/ctf" DEPLOY_DIR="$tmp/deploy"; "$2" "$tmp"); then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
  trap - EXIT
  rm -rf "$tmp"
}

assert_eq() {
  local got="$1" expected="$2" msg="${3:-}"
  if [[ "$got" != "$expected" ]]; then
    echo "  assert_eq failed${msg:+ ($msg)}: got '$got', expected '$expected'" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if ! grep -qF -e "$needle" <<< "$haystack"; then
    echo "  assert_contains failed${msg:+ ($msg)}: '$needle' not found in output" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if grep -qF -e "$needle" <<< "$haystack"; then
    echo "  assert_not_contains failed: '$needle' was found in output" >&2
    return 1
  fi
}

assert_fails() {
  if "$@"; then
    echo "  assert_fails: command succeeded unexpectedly: $*" >&2
    return 1
  fi
}

_build_golden() {
  if [[ ! -d "$GOLDEN_DIR/ctf" ]]; then
    mkdir -p "$GOLDEN_DIR"
    BUILD_DIR="$GOLDEN_DIR" CTF="$GOLDEN_DIR/ctf" bash "$ROOT/scripts/build.sh" >/dev/null
  fi
}

_build() {
  _build_golden
  # shellcheck disable=SC2031
  cp -R "$GOLDEN_DIR/ctf" "$CTF"
}

_wrong_verify_config() {
  local dir="$1"
  local alt_dir="$dir/alt-keys"
  mkdir -p "$alt_dir"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$alt_dir/private.pem" 2>/dev/null
  openssl rsa -pubout -in "$alt_dir/private.pem" \
    -out "$alt_dir/public.pem" 2>/dev/null

  local config_path="$dir/verify-wrong.ocmconfig"
  cat > "$config_path" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: ${alt_dir}/public.pem
EOF
  echo "$config_path"
}

_stub_kubectl() {
  local dir="$1" real_kubectl
  # Resolve the real binary now, before the stub is first on PATH.
  real_kubectl="$(command -v kubectl)"
  mkdir -p "$dir/stub-bin"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nif [[ "${1:-}" == kustomize ]]; then exec %q "$@"; fi\n' \
    "$real_kubectl" > "$dir/stub-bin/kubectl"
  cat >> "$dir/stub-bin/kubectl" <<'EOF'
echo "$*" >> "$(dirname "$0")/../kubectl.log"
if [[ "$*" == *" exec "* ]]; then echo "Hello, World!"; exit 0; fi
if [[ "${KUBECTL_FAIL:-0}" == "1" ]]; then
  exit 1
else
  exit 0
fi
EOF
  chmod 0755 "$dir/stub-bin/kubectl"
  echo "$dir/stub-bin"
}

_stub_kind() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/kind" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../kind.log"
cmd="${1:-}"
shift || true
case "$cmd" in
  get)
    case "${1:-}" in
      clusters) cat "$(dirname "$0")/../kind-clusters" 2>/dev/null || true ;;
      nodes) printf '%s\n' ocm-application-control-plane ocm-application-worker ;;
    esac
    ;;
  create)
    name_next=0
    for arg in "$@"; do
      if [[ "$name_next" -eq 1 ]]; then echo "$arg" >> "$(dirname "$0")/../kind-clusters"; name_next=0; fi
      [[ "$arg" == "--name" ]] && name_next=1
    done
    ;;
  delete)
    : > "$(dirname "$0")/../kind-clusters"
    ;;
  export)
    ;;
  *)
    echo "unknown kind subcommand: $*" >&2
    exit 1
    ;;
esac
exit 0
EOF
  chmod 0755 "$dir/stub-bin/kind"
  touch "$dir/kind-clusters"
  # stub docker so `require docker` passes; log its arguments and any stdin
  cat > "$dir/stub-bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../docker.log"
if [[ "${1:-}" == exec && "${2:-}" == -i ]]; then
  cat >> "$(dirname "$0")/../docker-stdin.log"
fi
EOF
  chmod 0755 "$dir/stub-bin/docker"
  echo "$dir/stub-bin"
}

# Records ocm argv and stdin instead of running ocm
_stub_ocm_record() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/ocm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/../ocm-args.log"
cat >> "$(dirname "$0")/../ocm-stdin.log"
EOF
  chmod 0755 "$dir/stub-bin/ocm"
}

# Wraps the real ocm: "get cv ... -o json" output is piped through the jq
# filter stored in $dir/stub-bin/image.jq; all other calls pass through.
_stub_ocm_rewrite_image() {
  local dir="$1" filter="$2"
  mkdir -p "$dir/stub-bin"
  printf '%s\n' "$filter" > "$dir/stub-bin/image.jq"
  cat > "$dir/stub-bin/ocm" <<'OCMEOF'
#!/usr/bin/env bash
REAL_OCM="${REAL_OCM:-ocm}"
if [[ "$*" == *"get cv"* ]] && [[ "$*" == *"-o json"* ]]; then
  "$REAL_OCM" "$@" | jq -f "$(dirname "$0")/image.jq"
else
  "$REAL_OCM" "$@"
fi
OCMEOF
  chmod 0755 "$dir/stub-bin/ocm"
  echo "$dir/stub-bin"
}

# Post-transfer shape: imageReference is an http:// URL without a digest
_stub_ocm_transferred_image() {
  _stub_ocm_rewrite_image "$1" '(.[0].component.resources[] | select(.name=="hello-world-image") | .access) = {"type":"ociArtifact/v1","imageReference":"http://localhost:5001/library/nginx:1.31-alpine"}'
}

_stub_ocm_tamper_localization() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/ocm" <<'OCMEOF'
#!/usr/bin/env bash
REAL_OCM="${REAL_OCM:-ocm}"
"$REAL_OCM" "$@" || exit $?
# After downloading the localization blob, append a byte to simulate tampering
if [[ "$*" == *"download resource"* ]] && [[ "$*" == *"name=hello-world-localization"* ]]; then
  out=""
  prev=""
  for arg in "$@"; do
    [[ "$prev" == "--output" ]] && out="$arg"
    prev="$arg"
  done
  printf 'x' >> "$out"
fi
OCMEOF
  chmod 0755 "$dir/stub-bin/ocm"
  echo "$dir/stub-bin"
}

_stub_ocm_tamper_config() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/ocm" <<'OCMEOF'
#!/usr/bin/env bash
REAL_OCM="${REAL_OCM:-ocm}"
"$REAL_OCM" "$@" || exit $?
# After downloading the config blob, append a byte to simulate tampering
if [[ "$*" == *"download resource"* ]] && [[ "$*" == *"name=hello-world-config"* ]]; then
  out=""
  prev=""
  for arg in "$@"; do
    [[ "$prev" == "--output" ]] && out="$arg"
    prev="$arg"
  done
  printf 'x' >> "$out"
fi
OCMEOF
  chmod 0755 "$dir/stub-bin/ocm"
  echo "$dir/stub-bin"
}

# Builds a CTF from a copy of the component sources. $2 is an optional sed
# expression applied to manifests.yaml, $3 an optional jq filter applied
# to localization.json and $4 an optional jq filter applied to config.json.
# Prints the CTF path.
_build_variant() {
  local dir="$1" manifest_expr="$2" loc_filter="$3" config_filter="${4:-}"
  local repo="$dir/variant-repo"
  rm -rf "$repo"
  mkdir -p "$repo"
  cp -R "$ROOT/component-constructor.yaml" "$ROOT/scripts" "$ROOT/components" "$repo/"
  if [[ -n "$manifest_expr" ]]; then
    sed "$manifest_expr" "$ROOT/components/hello-world/manifests.yaml" \
      > "$repo/components/hello-world/manifests.yaml"
  fi
  if [[ -n "$loc_filter" ]]; then
    jq "$loc_filter" "$ROOT/components/hello-world/localization.json" \
      > "$repo/components/hello-world/localization.json"
  fi
  [[ -z "$config_filter" ]] || \
    jq "$config_filter" "$ROOT/components/hello-world/config.json" > "$repo/components/hello-world/config.json"
  SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567" \
    BUILD_DIR="$dir/variant-build" CTF="$dir/variant-ctf" \
    bash "$repo/scripts/build.sh" >/dev/null
  echo "$dir/variant-ctf"
}

_build_ownership() {
  OWNERSHIP_CTF="$1/ownership-ctf" bash "$ROOT/scripts/ownership.sh" build >/dev/null
  echo "$1/ownership-ctf"
}

# Prints the digest of the ownership manifest recorded for resource $2 in CTF $1, or nothing.
_ownership_record_digest() {
  local ctf="$1" name="$2" ref referrers
  ref="$("$OCM" get cv "ctf::$ctf//github.com/lioramilbaum/ownership-demo:$VERSION" -o json \
    | jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .access.localReference')"
  referrers="$(jq -r --arg t "${ref/:/-}" \
    '[.artifacts[] | select(.tag==$t)] | first | .digest // ""' "$ctf/artifact-index.json")"
  [[ -n "$referrers" ]] || return 0
  jq -r '[.manifests[] | select(.artifactType=="application/vnd.ocm.software.ownership.v1+json")] | first | .digest // ""' \
    "$ctf/blobs/${referrers/:/.}"
}

# Prints how many ownership manifests are listed across all referrers indexes in CTF $1.
_ownership_record_count() {
  local ctf="$1" digest
  while IFS= read -r digest; do
    jq -r '.manifests[] | select(.artifactType=="application/vnd.ocm.software.ownership.v1+json") | .digest' \
      "$ctf/blobs/${digest/:/.}"
  done < <(jq -r '.artifacts[] | select((.tag // "") | startswith("sha256-")) | .digest' "$ctf/artifact-index.json") \
    | wc -l | tr -d ' '
}

_download_bundle() {
  local dest="$1"
  mkdir -p "$dest"
  # With auto extraction (default), OCM extracts directoryTree into the output directory
  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity name=deploy-bundle --output "$dest"
}

_empty_ocmconfig() {
  local dir="$1"
  local path="$dir/empty.ocmconfig"
  cat > "$path" <<'YAML'
type: generic.config.ocm.software/v1
configurations: []
YAML
  echo "$path"
}

# Builds a consumer CTF whose component references the application component
_resolver_consumer_ctf() {
  local dir="$1" config="$2"
  local constructor="$dir/consumer-constructor.yaml"
  cat > "$constructor" <<YAML
components:
  - name: example.com/resolver-demo/consumer
    version: "1.0.0"
    provider:
      name: example.com
    componentReferences:
      - name: application
        componentName: ${ROOT_COMPONENT}
        version: "${VERSION}"
YAML
  "$OCM" add cv \
    --repository "ctf::$dir/consumer-ctf" \
    --constructor "$constructor" \
    --config "$config" \
    --external-component-version-copy-policy skip >/dev/null
  echo "$dir/consumer-ctf"
}

# Dry-run transfer of the application component; prints the JSON plan.
_transfer_plan() {
  local target="$1"; shift
  "$OCM" transfer cv "$(cv_ref)" "$target" "$@" --dry-run -o json
}

# _build_product <tmp>
# Builds the golden app CTF (copied to $CTF), then builds the product CTF from it.
# The app is unsigned here; signing is only needed by tests that check signatures.
# Prints the product CTF path.
_build_product() {
  local tmp="$1"
  _build
  PRODUCT_CTF="$tmp/product-ctf" bash "$ROOT/scripts/product.sh" build >/dev/null
  echo "$tmp/product-ctf"
}

# _build_versions <tmp>
# Builds the release and nightly version CTFs into <tmp>.
_build_versions() {
  local tmp="$1"
  VERSIONS_CTF="$tmp/versions-ctf" \
  NIGHTLY_CTF="$tmp/nightly-ctf" \
    OCM="$VERSIONS_OCM" bash "$ROOT/scripts/versions.sh" build >/dev/null
}

# _build_helm <tmp>
# Builds the helm demo CTF into <tmp>/helm-ctf. No signing.
_build_helm() {
  local tmp="$1"
  HELM_DEMO_CTF="$tmp/helm-ctf" bash "$ROOT/scripts/helm.sh" build >/dev/null
}

# _helm_ref <ctf>
_helm_ref() {
  echo "ctf::${1}//github.com/lioramilbaum/helm-demo:${VERSION}"
}

# _product_ref <ctf>
# Prints the OCM reference for the product component in the given CTF.
_product_ref() {
  echo "ctf::${1}//github.com/lioramilbaum/product:${VERSION}"
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_build_produces_application_tree() {
  local tmp="$1"
  _build
  local count
  count=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    --recursive -o json 2>/dev/null | jq 'length')
  assert_eq "$count" "1" "component count"

  local resource_names
  resource_names=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq -r '.[0].component.resources[].name' | sort | paste -sd, -)
  assert_eq "$resource_names" "deploy-bundle,hello-world-config,hello-world-image,hello-world-image,hello-world-localization,hello-world-manifests,hello-world-sbom" "resource names"

  local image_archs
  image_archs=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq -r '[.[0].component.resources[] | select(.name=="hello-world-image") | .extraIdentity.architecture] | sort | join(",")')
  assert_eq "$image_archs" "amd64,arm64" "hello-world-image architectures" || return 1

  local ref_count
  ref_count=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq '.[0].component.componentReferences // [] | length')
  assert_eq "$ref_count" "0" "component references count"

  local provider
  provider=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq -r '.[0].component.provider')
  assert_eq "$provider" "github.com/lioramilbaum" "provider"
}

test_ocm_does_not_block_on_open_stdin() {
  local tmp="$1"
  _build
  local fifo="$tmp/stdin.fifo"
  mkfifo "$fifo"
  sleep 120 >"$fifo" &
  local holder=$!
  "$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json <"$fifo" >/dev/null 2>&1 &
  local pid=$! i
  # shellcheck disable=SC2034
  for i in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" "$holder" 2>/dev/null || true
    echo "  ocm blocked reading an open stdin pipe" >&2
    return 1
  fi
  kill "$holder" 2>/dev/null || true
  wait "$pid" || true
}

test_image_resource_is_pinned_by_digest() {
  local tmp="$1"
  _build
  local cv_json
  cv_json=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/application:${VERSION:-0.1.0}" -o json 2>/dev/null)

  local a rtype relation img expected_digest actual_digest
  for a in amd64 arm64; do
    rtype=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .type')
    assert_eq "$rtype" "ociImage" "$a image resource type" || return 1

    relation=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .relation // "external"')
    assert_eq "$relation" "external" "$a image relation" || return 1

    img=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .access.imageReference')
    [[ "$img" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "  $a image not pinned by digest: $img" >&2; return 1; }

    expected_digest=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .digest.value')
    actual_digest="${img##*@sha256:}"
    assert_eq "$actual_digest" "$expected_digest" "$a image digest match" || return 1
  done
}

test_manifests_resource_metadata() {
  local tmp="$1"
  _build
  local cv_json
  cv_json=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/application:${VERSION:-0.1.0}" -o json 2>/dev/null)

  local rtype mediatype rversion digest expected_digest
  rtype=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .type')
  assert_eq "$rtype" "blob" "manifests resource type"

  mediatype=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .access.mediaType')
  assert_eq "$mediatype" "application/yaml" "manifests mediaType"

  rversion=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .version')
  assert_eq "$rversion" "${VERSION:-0.1.0}" "manifests version"

  digest=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .digest.value')
  expected_digest="$(sha256 "$ROOT/components/hello-world/manifests.yaml")"
  assert_eq "$digest" "$expected_digest" "manifests digest"
}

test_localization_resource_metadata() {
  local tmp="$1"
  _build
  local cv_json
  cv_json=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/application:${VERSION:-0.1.0}" -o json 2>/dev/null)

  local rtype mediatype rversion digest expected_digest
  rtype=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-localization") | .type')
  assert_eq "$rtype" "localizationConfig" "localization resource type"

  mediatype=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-localization") | .access.mediaType')
  assert_eq "$mediatype" "application/json" "localization mediaType"

  rversion=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-localization") | .version')
  assert_eq "$rversion" "${VERSION:-0.1.0}" "localization version"

  digest=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-localization") | .digest.value')
  expected_digest="$(sha256 "$ROOT/components/hello-world/localization.json")"
  assert_eq "$digest" "$expected_digest" "localization digest"
}

test_sign_and_verify_succeed() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null
  [[ -f "$tmp/sign.ocmconfig" ]] || { echo "  sign.ocmconfig not created" >&2; return 1; }
  bash "$ROOT/scripts/verify.sh" >/dev/null
}

test_verify_rejects_wrong_key() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  local wrong_config
  wrong_config=$(_wrong_verify_config "$tmp")

  VERIFY_CONFIG="$wrong_config" assert_fails bash "$ROOT/scripts/verify.sh" 2>/dev/null
}

test_version_is_propagated() {
  local tmp="$1"
  export VERSION=9.9.9
  bash "$ROOT/scripts/build.sh" >/dev/null

  local cv_out component_version manifests_version
  cv_out=$("$OCM" get cv "ctf::${tmp}/ctf//github.com/lioramilbaum/application:9.9.9" -o json 2>/dev/null)
  component_version=$(echo "$cv_out" | jq -r '.[0].component.version')
  assert_eq "$component_version" "9.9.9" "component version"

  manifests_version=$(echo "$cv_out" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .version')
  assert_eq "$manifests_version" "9.9.9" "manifests version"
}

test_manifests_renders_pinned_image() {
  local tmp="$1"
  _build
  SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" >/dev/null

  local rendered
  rendered="$(cat "$tmp/deploy/hello-world.yaml")"

  assert_contains "$rendered" "kind: Deployment" "Deployment kind"
  assert_contains "$rendered" "name: hello-world" "deployment name"
  assert_contains "$rendered" "containerPort: 80" "container port"
  assert_contains "$rendered" "Hello, World!" "hello world message"
  assert_not_contains "$rendered" "$IMAGE_PLACEHOLDER" "placeholder removed"
  [[ "$rendered" =~ @sha256:[0-9a-f]{64} ]] || { echo "  Pinned image not found" >&2; return 1; }

  [[ -f "$tmp/deploy/kustomization.yaml" ]] || { echo "  kustomization.yaml not created" >&2; return 1; }
  local kust
  kust="$(cat "$tmp/deploy/kustomization.yaml")"
  assert_contains "$kust" "/spec/template/spec/containers/0/image" "kustomize image patch path"

  local img
  img=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>/dev/null \
    | jq -r --arg a "$TARGET_ARCH" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .access.imageReference')
  assert_contains "$rendered" "image: $img" "rendered image matches descriptor"
}

test_manifests_is_idempotent() {
  local tmp="$1"
  _build
  SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" >/dev/null
  SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" >/dev/null

  local count
  count=$(grep -c '^kind: Deployment' "$tmp/deploy/hello-world.yaml")
  assert_eq "$count" "1" "exactly one Deployment in rendered manifest"
}

test_cv_ref_honours_component_repo() {
  local tmp="$1" ref expected
  # shellcheck disable=SC2016
  ref="$(OCM_COMPONENT_REPO=oci::http://localhost:5001 bash -c 'source "$1"; cv_ref' _ "$ROOT/scripts/lib.sh")"
  expected="oci::http://localhost:5001//${ROOT_COMPONENT}:${VERSION:-0.1.0}"
  assert_eq "$ref" "$expected" "cv_ref with OCM_COMPONENT_REPO" || return 1

  # shellcheck disable=SC2016
  ref="$(env -u OCM_COMPONENT_REPO bash -c 'source "$1"; cv_ref' _ "$ROOT/scripts/lib.sh")"
  expected="ctf::$tmp/ctf//${ROOT_COMPONENT}:${VERSION:-0.1.0}"
  assert_eq "$ref" "$expected" "cv_ref without OCM_COMPONENT_REPO" || return 1
}

test_manifests_reads_from_component_repo() {
  local tmp="$1"
  _build

  # The original CTF path is gone; the component must come from OCM_COMPONENT_REPO
  OCM_COMPONENT_REPO="ctf::$tmp/ctf" CTF="$tmp/no-such-ctf" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" >/dev/null || return 1

  local rendered
  rendered="$(cat "$tmp/deploy/hello-world.yaml")"
  [[ "$rendered" =~ @sha256:[0-9a-f]{64} ]] || { echo "  Pinned image not found" >&2; return 1; }
}

test_manifests_localizes_transferred_image() {
  local tmp="$1"
  _build

  local stub_dir real_ocm
  stub_dir=$(_stub_ocm_transferred_image "$tmp")
  real_ocm="$OCM"

  # shellcheck disable=SC2097,SC2098
  REAL_OCM="$real_ocm" OCM="$stub_dir/ocm" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" >/dev/null || return 1

  local digest
  digest="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>/dev/null \
    | jq -r --arg a "$TARGET_ARCH" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .digest.value')"

  local rendered
  rendered="$(cat "$tmp/deploy/hello-world.yaml")"
  assert_contains "$rendered" "image: localhost:5001/library/nginx:1.31-alpine@sha256:$digest" "transferred image localized" || return 1
  assert_not_contains "$rendered" "http://" "scheme stripped" || return 1
  assert_not_contains "$rendered" "$IMAGE_PLACEHOLDER" "placeholder removed" || return 1
}

test_manifests_rejects_mismatched_image_digest() {
  local tmp="$1"
  _build

  local zeros
  printf -v zeros '%064d' 0
  local stub_dir real_ocm
  stub_dir=$(_stub_ocm_rewrite_image "$tmp" \
    "(.[0].component.resources[] | select(.name==\"hello-world-image\") | .access.imageReference) = \"ghcr.io/lioramilbaum/application/images/hello-world:latest@sha256:${zeros}\"")
  real_ocm="$OCM"

  local out
  # shellcheck disable=SC2097,SC2098
  if out=$(REAL_OCM="$real_ocm" OCM="$stub_dir/ocm" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with mismatched image digest" >&2
    return 1
  fi

  assert_contains "$out" "image digest mismatch" || return 1
  [[ ! -f "$tmp/deploy/hello-world.yaml" ]] || { echo "  Rendered file should not exist on failure" >&2; return 1; }
}

test_manifests_rejects_missing_image_digest() {
  local tmp="$1"
  _build

  local stub_dir real_ocm
  stub_dir=$(_stub_ocm_rewrite_image "$tmp" \
    '(.[0].component.resources[] | select(.name=="hello-world-image") | .digest) = null')
  real_ocm="$OCM"

  local out
  # shellcheck disable=SC2097,SC2098
  if out=$(REAL_OCM="$real_ocm" OCM="$stub_dir/ocm" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with missing image digest" >&2
    return 1
  fi

  assert_contains "$out" "no valid sha256 digest" || return 1
  [[ ! -f "$tmp/deploy/hello-world.yaml" ]] || { echo "  Rendered file should not exist on failure" >&2; return 1; }
}

test_manifests_localizes_by_rule_not_placeholder() {
  local tmp="$1"
  local ctf
  ctf=$(_build_variant "$tmp" 's|HELLO_WORLD_IMAGE|registry.invalid/not-localized:0|' "")

  local img
  img=$("$OCM" get cv "ctf::${ctf}//${ROOT_COMPONENT}:${VERSION:-0.1.0}" -o json 2>/dev/null \
    | jq -r --arg a "$TARGET_ARCH" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .access.imageReference')

  CTF="$ctf" SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" >/dev/null

  local rendered
  rendered="$(cat "$tmp/deploy/hello-world.yaml")"
  assert_contains "$rendered" "image: $img" "rule-localized image"
  assert_not_contains "$rendered" "registry.invalid" "manifest placeholder image must be replaced"
}

test_manifests_rejects_untargeted_localization() {
  local tmp="$1"
  local ctf
  ctf=$(_build_variant "$tmp" "" '.localizations[0].target.name = "does-not-exist"')

  local out
  if out=$(CTF="$ctf" SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with untargeted localization" >&2
    return 1
  fi

  assert_contains "$out" "localization"
  [[ ! -f "$tmp/deploy/hello-world.yaml" ]] || { echo "  Rendered file should not exist on failure" >&2; return 1; }
}

test_manifests_rejects_wrong_container() {
  local tmp="$1"
  local ctf
  ctf=$(_build_variant "$tmp" "" '.localizations[0].container.name = "other"')

  local out
  if out=$(CTF="$ctf" SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with wrong container name" >&2
    return 1
  fi

  assert_contains "$out" "kustomize localization failed"
  [[ ! -f "$tmp/deploy/hello-world.yaml" ]] || { echo "  Rendered file should not exist on failure" >&2; return 1; }
}

test_manifests_rejects_tampered_localization() {
  local tmp="$1"
  _build

  local stub_dir
  stub_dir=$(_stub_ocm_tamper_localization "$tmp")

  local out
  # shellcheck disable=SC2097,SC2098
  if out=$(REAL_OCM="$OCM" OCM="$stub_dir/ocm" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with tampered localization" >&2
    return 1
  fi

  assert_contains "$out" "localization blob digest mismatch"
  [[ ! -f "$tmp/deploy/hello-world.yaml" ]] || { echo "  Rendered file should not exist on failure" >&2; return 1; }
}

test_config_resource_metadata() {
  # uses golden dir directly (read-only; $1 unused)
  local tmp="$1"
  require "$OCM" jq
  local ctf
  _build_golden
  ctf="$GOLDEN_DIR/ctf"
  local cv_json
  cv_json="$("$OCM" get cv "ctf::${ctf}//${ROOT_COMPONENT}:${VERSION}" -o json)" || return 1
  local res_json
  res_json="$(echo "$cv_json" | jq -c '.[0].component.resources[] | select(.name=="hello-world-config")')" || return 1
  [[ -n "$res_json" ]] || { echo "hello-world-config resource not found"; return 1; }
  local rtype mediatype rver digest_val expected_digest
  rtype="$(echo "$res_json" | jq -r '.type')"
  mediatype="$(echo "$res_json" | jq -r '.access.mediaType')"
  rver="$(echo "$res_json" | jq -r '.version')"
  digest_val="$(echo "$res_json" | jq -r '.digest.value')"
  expected_digest="$(sha256 "$ROOT/components/hello-world/config.json")"
  [[ "$rtype" == "configData" ]] || { echo "expected type configData, got $rtype"; return 1; }
  [[ "$mediatype" == "application/json" ]] || { echo "expected mediaType application/json, got $mediatype"; return 1; }
  [[ "$rver" == "$VERSION" ]] || { echo "expected version $VERSION, got $rver"; return 1; }
  [[ "$digest_val" == "$expected_digest" ]] || { echo "digest mismatch: expected $expected_digest, got $digest_val"; return 1; }
}

test_manifests_applies_config_values() {
  local tmp="$1"
  require "$OCM" jq "$KUBECTL"
  local ctf
  ctf="$(_build_variant "$tmp" \
    '' \
    '' \
    '(.configurations[] | select(.name=="replicas") | .value) = 3 |
     (.configurations[] | select(.name=="index-html") | .value) = "Hello from signed config!\n"')" || return 1
  # Verify manifests.yaml has the placeholders (not literal values)
  grep -q "HELLO_WORLD_REPLICAS" "$ROOT/components/hello-world/manifests.yaml" || \
    { echo "HELLO_WORLD_REPLICAS placeholder missing from manifests.yaml"; return 1; }
  grep -q "HELLO_WORLD_HTML" "$ROOT/components/hello-world/manifests.yaml" || \
    { echo "HELLO_WORLD_HTML placeholder missing from manifests.yaml"; return 1; }
  local deploy_dir="$tmp/deploy"
  mkdir -p "$deploy_dir"
  local out
  out="$(CTF="$ctf" DEPLOY_DIR="$deploy_dir" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1)" || \
    { echo "manifests.sh failed: $out"; return 1; }
  local rendered="$deploy_dir/hello-world.yaml"
  [[ -f "$rendered" ]] || { echo "rendered manifest not found"; return 1; }
  grep -q "replicas: 3" "$rendered" || \
    { echo "replicas: 3 not found in rendered manifest"; return 1; }
  grep -q "Hello from signed config!" "$rendered" || \
    { echo "Hello from signed config! not found in rendered manifest"; return 1; }
  ! grep -qE "HELLO_WORLD_" "$rendered" || \
    { echo "unresolved placeholder found in rendered manifest"; return 1; }
  ! grep -q "Hello, World!" "$rendered" || \
    { echo "literal Hello, World! still present (config not applied)"; return 1; }
  grep -q "/spec/replicas" "$deploy_dir/kustomization.yaml" || \
    { echo "/spec/replicas not in kustomization.yaml"; return 1; }
  grep -q "/data/index.html" "$deploy_dir/kustomization.yaml" || \
    { echo "/data/index.html not in kustomization.yaml"; return 1; }
}

test_manifests_rejects_tampered_config() {
  local tmp="$1"
  require "$OCM" jq "$KUBECTL"
  local ctf
  ctf="$(_build_variant "$tmp" '' '')" || return 1
  local stub_dir
  stub_dir="$(_stub_ocm_tamper_config "$tmp")"
  local deploy_dir="$tmp/deploy"
  mkdir -p "$deploy_dir"
  local out
  # shellcheck disable=SC2097,SC2098
  out="$(REAL_OCM="$OCM" OCM="$stub_dir/ocm" CTF="$ctf" DEPLOY_DIR="$deploy_dir" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1)" && \
    { echo "expected failure, got success"; return 1; }
  echo "$out" | grep -q "config blob digest mismatch" || \
    { echo "expected 'config blob digest mismatch' in output, got: $out"; return 1; }
  [[ ! -f "$deploy_dir/hello-world.yaml" ]] || \
    { echo "rendered manifest should not exist after tamper"; return 1; }
}

test_manifests_rejects_untargeted_config() {
  local tmp="$1"
  require "$OCM" jq "$KUBECTL"
  local ctf
  ctf="$(_build_variant "$tmp" \
    '' \
    '' \
    '(.configurations[] | select(.name=="replicas") | .target.name) = "does-not-exist"')" || return 1
  local deploy_dir="$tmp/deploy"
  mkdir -p "$deploy_dir"
  local out
  out="$(CTF="$ctf" DEPLOY_DIR="$deploy_dir" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1)" && \
    { echo "expected failure, got success"; return 1; }
  # kustomize may error on unmatched targets (newer versions) or succeed and leave the
  # placeholder unreplaced (older versions); either way manifests.sh must reject the result
  echo "$out" | grep -qE "unresolved placeholder|kustomize localization failed" || \
    { echo "expected rejection message in output, got: $out"; return 1; }
  [[ ! -f "$deploy_dir/hello-world.yaml" ]] || \
    { echo "rendered manifest should not exist after untargeted config"; return 1; }
}

test_manifests_rejects_invalid_config() {
  local tmp="$1"
  require "$OCM" jq "$KUBECTL"
  local ctf
  ctf="$(_build_variant "$tmp" '' '' '.kind = "Bogus"')" || return 1
  local deploy_dir="$tmp/deploy"
  mkdir -p "$deploy_dir"
  local out
  out="$(CTF="$ctf" DEPLOY_DIR="$deploy_dir" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1)" && \
    { echo "expected failure, got success"; return 1; }
  echo "$out" | grep -q "unsupported config data" || \
    { echo "expected 'unsupported config data' in output, got: $out"; return 1; }
  [[ ! -f "$deploy_dir/hello-world.yaml" ]] || \
    { echo "rendered manifest should not exist after invalid config"; return 1; }
}

# jq must be available; deploy.sh requires it before reaching the verify block
test_deploy_verifies_before_deploying() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  local wrong_config
  wrong_config=$(_wrong_verify_config "$tmp")

  local stub_dir
  stub_dir=$(_stub_kubectl "$tmp")

  if PATH="$stub_dir:$PATH" VERIFY_CONFIG="$wrong_config" \
    bash "$ROOT/scripts/deploy.sh" >/dev/null 2>&1; then
    echo "  Should have failed with wrong key" >&2
    return 1
  fi

  [[ ! -f "$tmp/kubectl.log" ]] || { echo "  kubectl should not have been invoked" >&2; return 1; }
}

test_deploy_applies_rendered_manifests() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  local stub_dir
  stub_dir=$(_stub_kubectl "$tmp")

  PATH="$stub_dir:$PATH" bash "$ROOT/scripts/deploy.sh" >/dev/null 2>&1 || true

  [[ -f "$tmp/kubectl.log" ]] || { echo "  kubectl.log not created" >&2; return 1; }

  local log
  log=$(cat "$tmp/kubectl.log")
  assert_contains "$log" "apply -f" "kubectl apply command"
  assert_contains "$log" "hello-world.yaml" "manifest filename"
  assert_contains "$log" "rollout status deployment/hello-world" "rollout status command"
}

test_deploy_fails_when_rollout_fails() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  local stub_dir
  stub_dir=$(_stub_kubectl "$tmp")

  if PATH="$stub_dir:$PATH" KUBECTL_FAIL=1 bash "$ROOT/scripts/deploy.sh" >/dev/null 2>&1; then
    echo "  Should have failed when kubectl fails" >&2
    return 1
  fi
}

test_deploy_bundle_metadata() {
  local tmp="$1"
  _build
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  local rtype rversion
  rtype="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="deploy-bundle") | .type')"
  assert_eq "$rtype" "directoryTree" "deploy-bundle type"

  rversion="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="deploy-bundle") | .version')"
  assert_eq "$rversion" "$VERSION" "deploy-bundle version"

  # Download deploy-bundle and verify it
  local bundle tar_file tar_digest expected_digest
  bundle="$(mktemp -d "$tmp/bundle.XXXXXX")"
  tar_file="$bundle/deploy-bundle.tar.gz"
  rm -f "$tar_file"
  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity name=deploy-bundle --output "$tar_file" --extraction-policy disable

  tar_digest="$(sha256 "$tar_file")"
  expected_digest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="deploy-bundle") | .digest.value')"
  # Strip algorithm prefix (e.g., "sha256:...") if present
  expected_digest="${expected_digest#*:}"
  assert_eq "$tar_digest" "$expected_digest" "deploy-bundle tar digest match"

  # Verify tar contents
  local tar_contents
  tar_contents="$(tar -tzf "$tar_file" | grep -v '/$' | sort | paste -sd, -)"
  assert_eq "$tar_contents" "component-constructor.yaml,scripts/deploy.sh,scripts/lib.sh,scripts/manifests.sh,scripts/verify.sh" "deploy-bundle contents"

  # Verify build-time scripts are NOT in the tar
  for script in build sign publish keys sigstore e2e cluster sbom; do
    assert_not_contains "$tar_contents" "scripts/$script.sh" "scripts/$script.sh must not be in deploy-bundle"
  done
}

test_deploy_bundle_download_identical() {
  local tmp="$1"
  _build
  local bundle
  bundle="$(mktemp -d "$tmp/bundle.XXXXXX")"
  _download_bundle "$bundle"

  local s
  for s in lib verify manifests deploy; do
    cmp "$bundle/scripts/$s.sh" "$ROOT/scripts/$s.sh" || \
      { echo "  script-$s download differs from repo source" >&2; return 1; }
  done
  cmp "$bundle/component-constructor.yaml" "$ROOT/component-constructor.yaml" || \
    { echo "  component-constructor download differs from repo source" >&2; return 1; }
}

test_source_references_git_commit() {
  local tmp="$1"
  export SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567"
  bash "$ROOT/scripts/build.sh" >/dev/null
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  local sources_len
  sources_len="$(echo "$cv_json" | jq '.[0].component.sources // [] | length')"
  assert_eq "$sources_len" "1" "sources count"

  local src_name src_type src_version repo_url commit
  src_name="$(echo "$cv_json" | jq -r '.[0].component.sources[0].name')"
  assert_eq "$src_name" "application-source" "source name"

  src_type="$(echo "$cv_json" | jq -r '.[0].component.sources[0].type')"
  assert_eq "$src_type" "git" "source type"

  src_version="$(echo "$cv_json" | jq -r '.[0].component.sources[0].version')"
  assert_eq "$src_version" "$VERSION" "source version"

  src_access_type="$(echo "$cv_json" | jq -r '.[0].component.sources[0].access.type')"
  assert_eq "$src_access_type" "GitHub/v1" "source access type"

  repo_url="$(echo "$cv_json" | jq -r '.[0].component.sources[0].access.repoUrl')"
  assert_eq "$repo_url" "https://github.com/lioramilbaum/application" "source repoUrl"

  commit="$(echo "$cv_json" | jq -r '.[0].component.sources[0].access.commit')"
  assert_eq "$commit" "0123456789abcdef0123456789abcdef01234567" "source commit"
}

test_build_rejects_invalid_source_commit() {
  local tmp="$1"
  if SOURCE_COMMIT="not-a-sha" bash "$ROOT/scripts/build.sh" >/dev/null 2>&1; then
    echo "  build should reject invalid SOURCE_COMMIT" >&2
    return 1
  fi
  local out
  out="$(SOURCE_COMMIT="not-a-sha" bash "$ROOT/scripts/build.sh" 2>&1 || true)"
  assert_contains "$out" "SOURCE_COMMIT must be"
}

test_verify_ignores_other_signatures() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  # Add a second RSA signature with a different name (should not break verification)
  local alt_dir="$tmp/alt-keys"
  mkdir -p "$alt_dir"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$alt_dir/private.pem" 2>/dev/null
  openssl rsa -pubout -in "$alt_dir/private.pem" \
    -out "$alt_dir/public.pem" 2>/dev/null

  cat > "$tmp/sign-other.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: other
        credentials:
          - type: RSACredentials/v1
            privateKeyPEMFile: ${alt_dir}/private.pem
            publicKeyPEMFile: ${alt_dir}/public.pem
EOF

  # Sign with "other" signature
  VERIFY_CONFIG="$tmp/sign-other.ocmconfig" "$OCM" sign cv \
    --config "$tmp/sign-other.ocmconfig" \
    --signature "other" \
    "$(cv_ref "$ROOT_COMPONENT")" < /dev/null

  # Assert "other" signature was added
  local sigs
  sigs="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json | jq -r '.[0].signatures[].name' | sort | paste -sd, -)"
  assert_eq "$sigs" "default,other" "both signatures should be present after alt-sign"

  # Verify should still succeed with the default signature
  bash "$ROOT/scripts/verify.sh" >/dev/null
}

test_sigstore_config_generation() {
  local tmp="$1"
  bash "$ROOT/scripts/sigstore.sh" >/dev/null

  [[ -f "$tmp/sign-sigstore.ocmconfig" ]] || { echo "  sign-sigstore.ocmconfig not created" >&2; return 1; }
  [[ -f "$tmp/verify-sigstore.ocmconfig" ]] || { echo "  verify-sigstore.ocmconfig not created" >&2; return 1; }

  local sign_config verify_config
  sign_config="$(cat "$tmp/sign-sigstore.ocmconfig")"
  verify_config="$(cat "$tmp/verify-sigstore.ocmconfig")"

  assert_contains "$sign_config" "SigstoreSigningConfiguration"
  assert_contains "$verify_config" "SigstoreVerificationConfiguration"
  assert_contains "$verify_config" "certificateOIDCIssuer"
  assert_contains "$verify_config" "certificateIdentityRegexp"
}

test_sigstore_sign_requires_oidc_token() {
  local tmp="$1"
  _build

  if env -u SIGSTORE_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    SIGNING_METHOD=sigstore bash "$ROOT/scripts/sign.sh" >/dev/null 2>&1; then
    echo "  sigstore sign should require OIDC token" >&2
    return 1
  fi

  local out
  out="$(env -u SIGSTORE_ID_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    SIGNING_METHOD=sigstore bash "$ROOT/scripts/sign.sh" 2>&1 || true)"
  assert_contains "$out" "OIDC token"
}

test_sign_rejects_unknown_signing_method() {
  local tmp="$1"
  _build

  if SIGNING_METHOD=bogus bash "$ROOT/scripts/sign.sh" >/dev/null 2>&1; then
    echo "  sign should reject unknown SIGNING_METHOD" >&2
    return 1
  fi
}

test_bundle_is_self_contained() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null
  local bundle
  bundle="$(mktemp -d "$tmp/bundle.XXXXXX")"
  _download_bundle "$bundle"

  # Verify bundle structure
  [[ -f "$bundle/scripts/lib.sh" ]] || { echo "  lib.sh missing from bundle" >&2; return 1; }
  [[ -f "$bundle/scripts/verify.sh" ]] || { echo "  verify.sh missing from bundle" >&2; return 1; }
  [[ -f "$bundle/scripts/manifests.sh" ]] || { echo "  manifests.sh missing from bundle" >&2; return 1; }
  [[ -f "$bundle/scripts/deploy.sh" ]] || { echo "  deploy.sh missing from bundle" >&2; return 1; }
  [[ -f "$bundle/component-constructor.yaml" ]] || { echo "  component-constructor.yaml missing from bundle" >&2; return 1; }

  # Test that bundled deploy.sh works with minimal environment
  local stub_dir
  stub_dir=$(_stub_kubectl "$tmp")

  # Source bundle lib and test it loads component-constructor
  (
    # shellcheck source=/dev/null
    source "$bundle/scripts/lib.sh"
    PATH="$stub_dir:$PATH" SKIP_VERIFY=1 bash "$bundle/scripts/manifests.sh" >/dev/null || \
      { echo "  bundled manifests.sh failed" >&2; return 1; }
  )
}

# Tests for cluster.sh

test_cluster_sh_creates_missing_cluster() {
  local tmp="$1"
  local stub_dir
  stub_dir=$(_stub_kind "$tmp")
  BUILD_DIR="$tmp/build" KIND="$stub_dir/kind" E2E_KUBECONFIG="$tmp/build/e2e/kubeconfig" \
    PATH="$stub_dir:$PATH" \
    bash "$ROOT/scripts/cluster.sh" up
  assert_contains "$(cat "$tmp/kind.log")" "create cluster --name ocm-application"
}

test_cluster_sh_reuses_existing_cluster() {
  local tmp="$1"
  local stub_dir
  stub_dir=$(_stub_kind "$tmp")
  echo "ocm-application" > "$tmp/kind-clusters"
  BUILD_DIR="$tmp/build" KIND="$stub_dir/kind" E2E_KUBECONFIG="$tmp/build/e2e/kubeconfig" \
    PATH="$stub_dir:$PATH" \
    bash "$ROOT/scripts/cluster.sh" up
  assert_not_contains "$(cat "$tmp/kind.log")" "create cluster"
  assert_contains "$(cat "$tmp/kind.log")" "export kubeconfig --name ocm-application"
}

test_cluster_sh_down_deletes_cluster() {
  local tmp="$1"
  local stub_dir
  stub_dir=$(_stub_kind "$tmp")
  echo "ocm-application" > "$tmp/kind-clusters"
  BUILD_DIR="$tmp/build" KIND="$stub_dir/kind" E2E_KUBECONFIG="$tmp/build/e2e/kubeconfig" \
    bash "$ROOT/scripts/cluster.sh" down
  assert_contains "$(cat "$tmp/kind.log")" "delete cluster --name ocm-application"
}

test_cluster_sh_configures_local_registry_mirror() {
  local tmp="$1"
  local stub_dir
  stub_dir=$(_stub_kind "$tmp")
  BUILD_DIR="$tmp/build" KIND="$stub_dir/kind" E2E_KUBECONFIG="$tmp/build/e2e/kubeconfig" \
    KIND_REGISTRY_HOST=localhost:5001 KIND_REGISTRY_ENDPOINT=http://kind-registry:5000 \
    PATH="$stub_dir:$PATH" \
    bash "$ROOT/scripts/cluster.sh" up >/dev/null || return 1

  local log
  log="$(cat "$tmp/docker.log")"
  assert_contains "$log" "exec ocm-application-control-plane mkdir -p /etc/containerd/certs.d/localhost:5001" || return 1
  assert_contains "$log" "exec ocm-application-worker mkdir -p /etc/containerd/certs.d/localhost:5001" || return 1
  assert_contains "$log" "exec -i ocm-application-control-plane tee /etc/containerd/certs.d/localhost:5001/hosts.toml" || return 1
  assert_contains "$log" "exec -i ocm-application-worker tee /etc/containerd/certs.d/localhost:5001/hosts.toml" || return 1
  assert_contains "$(cat "$tmp/docker-stdin.log")" '[host."http://kind-registry:5000"]' || return 1

  # Without the registry vars, no containerd certs.d configuration is written
  rm -f "$tmp/docker.log" "$tmp/docker-stdin.log"
  BUILD_DIR="$tmp/build" KIND="$stub_dir/kind" E2E_KUBECONFIG="$tmp/build/e2e/kubeconfig" \
    PATH="$stub_dir:$PATH" \
    bash "$ROOT/scripts/cluster.sh" up >/dev/null || return 1
  assert_not_contains "$(cat "$tmp/docker.log" 2>/dev/null || true)" "certs.d" || return 1
}

test_make_e2e_run_skips_build_sign() {
  local tmp="$1"
  local out
  out="$(make -s --dry-run -C "$ROOT" e2e-run 2>&1)"
  assert_contains "$out" "scripts/e2e.sh"
  assert_not_contains "$out" "scripts/build.sh"
  assert_not_contains "$out" "scripts/sign.sh"
}

test_devcontainer_config_is_valid() {
  local tmp="$1"
  local cfg="$ROOT/.devcontainer/devcontainer.json"
  [[ -f "$cfg" ]] || die "devcontainer.json not found"
  jq -e '(.features | keys | map(test("docker-outside-of-docker"))) | any' \
    "$cfg" > /dev/null || die "docker-outside-of-docker feature not found"
  jq -e '(.features | keys | map(test("docker-in-docker")) | any) | not' \
    "$cfg" > /dev/null || die "docker-in-docker must not be used"
  jq -e '.runArgs | index("--network=host") != null' \
    "$cfg" > /dev/null || die "--network=host missing from runArgs"
  jq -e 'has("postCreateCommand") | not' "$cfg" > /dev/null || die "postCreateCommand must not be set"
  jq -e 'has("remoteEnv") | not' "$cfg" > /dev/null || die "remoteEnv must not be set"
}

test_devcontainer_pins_tools() {
  local df="$ROOT/.devcontainer/Dockerfile"
  [[ -f "$df" ]] || die "Dockerfile not found"
  grep -qE '^ARG OCM_CLI_VERSION=v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' "$df" || die "OCM_CLI_VERSION ARG not found in Dockerfile"
  grep -qE '^ARG KIND_VERSION=v[0-9.]+$' "$df" || die "KIND_VERSION ARG not found in Dockerfile"
  local sha_count
  sha_count=$(grep -cE '^ARG (OCM|KIND)_SHA256_LINUX_(AMD64|ARM64)=[0-9a-f]{64}$' "$df")
  [[ "$sha_count" -eq 4 ]] || die "Expected 4 SHA256 ARGs, got $sha_count"
  grep -q 'sha256sum -c' "$df" || die "sha256sum -c not found in Dockerfile"
  local rv="$ROOT/renovate.json"
  jq -e '
    [.customManagers[] | select((.managerFilePatterns // .fileMatch)[] | test("Dockerfile"))] |
    (map(select(.matchStrings[] | test("OCM_CLI_VERSION"))) | length) == 1 and
    (map(select(.matchStrings[] | test("KIND_VERSION"))) | length) == 1
  ' "$rv" > /dev/null || die "renovate.json missing Dockerfile ARG managers"
  jq -e '
    [.customManagers[] | select((.managerFilePatterns // .fileMatch)[] | test("fetch-"))] | length == 0
  ' "$rv" > /dev/null || die "renovate.json still references fetch- scripts"
}

test_renovate_updates_ocm_sha256() {
  local df="$ROOT/.devcontainer/Dockerfile" rv="$ROOT/renovate.json"
  local ocm_version arch sha
  ocm_version=$(sed -n 's/^ARG OCM_CLI_VERSION=//p' "$df")
  [[ -n "$ocm_version" ]] || die "OCM_CLI_VERSION not found in Dockerfile"
  # Renovate targets stable releases; skip version-specific checks for pre-release pins
  if [[ "$ocm_version" != *-* ]]; then
    for arch in AMD64 ARM64; do
      sha=$(sed -n "s/^ARG OCM_SHA256_LINUX_${arch}=//p" "$df")
      jq -e -Rs --slurpfile cfg "$rv" --arg arch "$arch" --arg v "$ocm_version" --arg sha "$sha" '
        . as $df
        | [ $cfg[0].customManagers[]
            | select(.datasourceTemplate == "github-release-attachments"
                     and .depNameTemplate == "open-component-model/open-component-model"
                     and (.matchStrings[0] | contains("OCM_SHA256_LINUX_" + $arch + "=(?<currentDigest>"))) ]
        | length == 1
          and (.[0].matchStrings[0] as $re
               | [ $df | capture($re; "g") ]
               | length == 1 and .[0].currentValue == $v and .[0].currentDigest == $sha)
      ' "$df" > /dev/null || die "renovate.json does not track OCM_SHA256_LINUX_${arch} at ${ocm_version}"
    done
    jq -e -Rs --slurpfile cfg "$rv" '
      . as $df
      | [ $cfg[0].customManagers[]
          | select(.depNameTemplate == "open-component-model/open-component-model")
          | .matchStrings[] as $re
          | $df | match($re; "g") | [.offset, .offset + .length] ]
      | sort | . as $s
      | length == 3 and all(range(1; $s | length); $s[.][0] >= $s[. - 1][1])
    ' "$df" > /dev/null || die "OCM Renovate matches overlap or are missing"
  fi
  jq -e '
    [ .packageRules[]?
      | select((.matchDepNames // []) | index("open-component-model/open-component-model"))
      | .groupName // empty ] | length == 1
  ' "$rv" > /dev/null || die "OCM dependencies are not grouped into one PR"
}

test_e2e_workflow_isolates_deploy() {
  local wf="$ROOT/.github/workflows/e2e.yaml"
  [[ -f "$wf" ]] || { echo "FAIL: e2e.yaml not found"; return 1; }
  local deploy
  deploy="$(sed -n '/^  deploy:/,$p' "$wf")"

  assert_contains "$deploy" "make cluster-up"         || return 1
  assert_contains "$deploy" "crictl pull"             || return 1
  assert_contains "$deploy" "iptables -I DOCKER-USER" || return 1
  assert_contains "$deploy" "--ctstate NEW"           || return 1
  assert_contains "$deploy" "-j DROP"                 || return 1
  assert_contains "$deploy" "tcpdump"                 || return 1
  assert_contains "$deploy" "iptables -D DOCKER-USER" || return 1
  assert_contains "$deploy" "make e2e-run"            || return 1
  assert_contains "$deploy" "e2e-public-egress.pcap"  || return 1
  assert_contains "$deploy" "upload-artifact"         || return 1

  # Ordering: cluster-up < crictl pull < iptables -I < make e2e-run < iptables -D
  local cluster_line iptables_i_line erun_line iptables_d_line crictl_line
  cluster_line=$(echo "$deploy"   | grep -n 'make cluster-up'         | head -1 | cut -d: -f1)
  crictl_line=$(echo "$deploy"    | grep -n 'crictl pull'             | head -1 | cut -d: -f1)
  iptables_i_line=$(echo "$deploy"| grep -n 'iptables -I DOCKER-USER' | head -1 | cut -d: -f1)
  erun_line=$(echo "$deploy"      | grep -n 'make e2e-run'            | head -1 | cut -d: -f1)
  iptables_d_line=$(echo "$deploy"| grep -n 'iptables -D DOCKER-USER' | head -1 | cut -d: -f1)

  [[ -n "$cluster_line" && -n "$crictl_line" && -n "$iptables_i_line" && -n "$erun_line" && -n "$iptables_d_line" ]] || \
    { echo "FAIL: ordering lines not all found"; return 1; }
  [[ "$cluster_line" -lt "$crictl_line" ]]     || { echo "FAIL: cluster-up must precede crictl pull"; return 1; }
  [[ "$crictl_line" -lt "$iptables_i_line" ]]  || { echo "FAIL: crictl pull must precede iptables block"; return 1; }
  [[ "$iptables_i_line" -lt "$erun_line" ]]    || { echo "FAIL: iptables block must precede make e2e-run"; return 1; }
  [[ "$erun_line" -lt "$iptables_d_line" ]]    || { echo "FAIL: make e2e-run must precede iptables remove"; return 1; }

  # restore step must have if: always() && steps.egress.outcome
  assert_contains "$deploy" "always() && steps.egress.outcome" || return 1
  # upload step must also have if: always()
  assert_contains "$deploy" "always()" || return 1

  # package job must not contain iptables or tcpdump
  local pkg
  pkg="$(sed -n '/^  package:/,/^  deploy:/p' "$wf")"
  assert_not_contains "$pkg" "iptables" || return 1
  assert_not_contains "$pkg" "tcpdump"  || return 1
}

# Tests for registry credential publishing

# Runs publish.sh against the recording ocm stub; extra args are VAR=value pairs.
# stdin is /dev/null so the stub never blocks when no credentials are piped in.
_run_publish_stubbed() {
  local tmp="$1"
  shift
  _stub_ocm_record "$tmp"
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD -u OCM_REGISTRY_HOST \
    OCM=ocm PATH="$tmp/stub-bin:$PATH" OCM_REPO=oci://ghcr.io/example/ocm "$@" \
    bash "$ROOT/scripts/publish.sh" < /dev/null
}

test_publish_passes_registry_credentials_via_ocm_config() {
  local tmp="$1"
  _run_publish_stubbed "$tmp" OCM_REGISTRY_USERNAME=demo-user OCM_REGISTRY_PASSWORD=demo-secret >/dev/null || return 1

  local args stdin
  args="$(cat "$tmp/ocm-args.log")"
  stdin="$(cat "$tmp/ocm-stdin.log")"
  assert_contains "$args" "--config -" || return 1
  assert_contains "$args" "transfer cv" || return 1
  assert_contains "$args" "ghcr.io/example/ocm" || return 1
  assert_contains "$stdin" "type: OCIRegistry" || return 1
  assert_contains "$stdin" "hostname: 'ghcr.io'" || return 1
  assert_contains "$stdin" "type: OCICredentials/v1" || return 1
  assert_contains "$stdin" "demo-user" || return 1
  assert_contains "$stdin" "demo-secret" || return 1
  assert_contains "$stdin" "type: DockerConfig/v1" || return 1
}

test_publish_does_not_write_registry_secret() {
  local tmp="$1"
  _run_publish_stubbed "$tmp" OCM_REGISTRY_USERNAME=demo-user OCM_REGISTRY_PASSWORD=demo-secret >/dev/null || return 1

  if grep -rl demo-secret "$tmp" --exclude=ocm-stdin.log; then
    echo "  registry password was written to disk" >&2
    return 1
  fi
}

test_publish_without_registry_credentials_uses_discovery() {
  local tmp="$1"
  _run_publish_stubbed "$tmp" >/dev/null || return 1

  local args
  args="$(cat "$tmp/ocm-args.log")"
  assert_contains "$args" "transfer cv" || return 1
  assert_not_contains "$args" "--config" || return 1
}

test_publish_rejects_partial_registry_credentials() {
  local tmp="$1" out
  if out="$(_run_publish_stubbed "$tmp" OCM_REGISTRY_USERNAME=demo-user 2>&1)"; then
    echo "  publish should fail when only the username is set" >&2
    return 1
  fi

  assert_contains "$out" "OCM_REGISTRY_PASSWORD" || return 1
  [[ ! -f "$tmp/ocm-args.log" ]] || { echo "  ocm must not run with partial credentials" >&2; return 1; }
}

test_registry_identity_derived_from_ocm_repo() {
  local tmp="$1" input want got
  unset OCM_REGISTRY_HOST
  source "$ROOT/scripts/lib.sh"
  source "$ROOT/scripts/registry-credentials.sh"

  while IFS='|' read -r input want; do
    got="$(registry_endpoint "$input" | paste -sd/ -)"
    assert_eq "$got" "$want" "registry identity for $input" || return 1
  done <<'TABLE'
ghcr.io/x/ocm|ghcr.io/
oci://ghcr.io/x/ocm|ghcr.io/
oci::http://localhost:5001|localhost/5001
http://localhost:5001/x|localhost/5001
TABLE

  got="$(OCM_REGISTRY_HOST=registry.example.com registry_endpoint "oci::http://localhost:5001" | paste -sd/ -)"
  assert_eq "$got" "registry.example.com/" "OCM_REGISTRY_HOST override" || return 1
}

test_registry_ocmconfig_is_valid_for_ocm() {
  local tmp="$1"
  source "$ROOT/scripts/lib.sh"
  source "$ROOT/scripts/registry-credentials.sh"

  OCM_REPO=oci://ghcr.io/example/ocm OCM_REGISTRY_USERNAME=demo OCM_REGISTRY_PASSWORD="p'a#s: s" \
    render_registry_ocmconfig > "$tmp/registry.ocmconfig" || return 1
  assert_contains "$(cat "$tmp/registry.ocmconfig")" "password: 'p''a#s: s'" || return 1

  if ! command -v "$OCM" >/dev/null 2>&1; then
    echo "  skip: ocm not found in PATH, skipping real-binary parse check"
  else
    "$OCM" --config "$tmp/registry.ocmconfig" version >/dev/null 2>&1 || {
      echo "  ocm rejected the rendered registry config" >&2
      return 1
    }
  fi

  # A fresh bash process: errexit is suppressed inside an if/|| context, which would mask the failure
  if OCM_REPO=oci://ghcr.io/example/ocm OCM_REGISTRY_USERNAME=demo OCM_REGISTRY_PASSWORD=$'p\nw' \
    bash -c 'source "$1"; source "$2"; render_registry_ocmconfig' _ \
    "$ROOT/scripts/lib.sh" "$ROOT/scripts/registry-credentials.sh" >/dev/null 2>&1; then
    echo "  rendering a password with a newline should fail" >&2
    return 1
  fi
}

test_release_publishes_with_ocm_credentials() {
  local tmp="$1" step
  step="$(sed -n '/- name: Publish component to GHCR/,/- name:/p' "$ROOT/.github/workflows/release.yaml")"
  assert_contains "$step" "OCM_REGISTRY_USERNAME:" || return 1
  assert_contains "$step" "OCM_REGISTRY_PASSWORD:" || return 1
  assert_contains "$step" "secrets.GITHUB_TOKEN" || return 1
  assert_contains "$step" "make publish" || return 1
  assert_not_contains "$step" "docker login" || return 1
}

test_resolvers_config_is_valid_for_ocm() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  GOLDEN_DIR="$tmp" BUILD_DIR="$tmp" _build

  BUILD_DIR="$tmp" bash "$ROOT/scripts/resolvers.sh" >/dev/null

  local cfg="$tmp/resolvers.ocmconfig"
  [[ -f "$cfg" ]] || { echo "  resolvers.ocmconfig not created" >&2; return 1; }
  assert_contains "$(cat "$cfg")" "type: resolvers.config.ocm.software/v1alpha1" || return 1
  assert_contains "$(cat "$cfg")" 'componentNamePattern: "github.com/lioramilbaum/**"' || return 1
  assert_contains "$(cat "$cfg")" "type: CommonTransportFormat/v1" || return 1
  assert_contains "$(cat "$cfg")" "filePath: \"${CTF}\"" || return 1
  # OCM silently ignores unknown keys; prove the correct ones are present
  assert_not_contains "$(cat "$cfg")" "component:" || return 1
  assert_not_contains "$(cat "$cfg")" "version:" || return 1

  # ocm get cv compiles the glob and version constraint — use it as the real parse check
  "$OCM" get cv "$(cv_ref)" --config "$cfg" -o json > /dev/null

  # A bad glob must be rejected when the resolver is invoked
  local bad_cfg="$tmp/bad.ocmconfig"
  sed 's|github.com/lioramilbaum/\*\*|github.com/[unclosed|' "$tmp/resolvers.ocmconfig" > "$bad_cfg"
  local consumer_ctf_bad
  consumer_ctf_bad="$(_resolver_consumer_ctf "$tmp" "$tmp/resolvers.ocmconfig")"
  assert_fails "$OCM" get cv "ctf::${consumer_ctf_bad}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$bad_cfg" -o json
}

test_resolvers_resolve_component_reference() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  GOLDEN_DIR="$tmp" BUILD_DIR="$tmp" _build
  BUILD_DIR="$tmp" bash "$ROOT/scripts/resolvers.sh" >/dev/null

  local consumer_ctf
  consumer_ctf="$(_resolver_consumer_ctf "$tmp" "$tmp/resolvers.ocmconfig")"

  # With resolvers: both components appear in recursive get
  local result
  result="$("$OCM" get cv "ctf::${consumer_ctf}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$tmp/resolvers.ocmconfig" -o json)"
  local names
  names="$(printf '%s' "$result" | jq -r '.[].component.name' | sort | paste -sd, -)"
  assert_eq "$names" "example.com/resolver-demo/consumer,github.com/lioramilbaum/application" "resolved components" || return 1

  # Without resolvers: recursive get fails (reference cannot be resolved)
  local empty_cfg
  empty_cfg="$(_empty_ocmconfig "$tmp")"
  assert_fails "$OCM" get cv "ctf::${consumer_ctf}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$empty_cfg" -o json
}

test_resolvers_honour_version_constraint_and_order() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  GOLDEN_DIR="$tmp" BUILD_DIR="$tmp" _build
  BUILD_DIR="$tmp" bash "$ROOT/scripts/resolvers.sh" >/dev/null

  local consumer_ctf
  consumer_ctf="$(_resolver_consumer_ctf "$tmp" "$tmp/resolvers.ocmconfig")"

  # Version constraint that excludes the application version must fail
  local constrained_cfg="$tmp/constrained.ocmconfig"
  cat > "$constrained_cfg" <<YAML
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: CommonTransportFormat/v1
          filePath: "${CTF}"
          accessMode: readonly
        componentNamePattern: "github.com/lioramilbaum/**"
        versionConstraint: ">=99.0.0"
YAML
  assert_fails "$OCM" get cv "ctf::${consumer_ctf}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$constrained_cfg" -o json

  # First-match-wins: an empty CTF listed before the real one must fail
  mkdir -p "$tmp/empty-ctf"
  local order_bad_cfg="$tmp/order-bad.ocmconfig"
  cat > "$order_bad_cfg" <<YAML
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: CommonTransportFormat/v1
          filePath: "$tmp/empty-ctf"
          accessMode: readonly
        componentNamePattern: "github.com/**"
      - repository:
          type: CommonTransportFormat/v1
          filePath: "${CTF}"
          accessMode: readonly
        componentNamePattern: "github.com/lioramilbaum/**"
YAML
  # OCM selects the first matching entry with no fallback to later ones.
  assert_fails "$OCM" get cv "ctf::${consumer_ctf}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$order_bad_cfg" -o json

  # Same entries in the opposite order must succeed
  local order_good_cfg="$tmp/order-good.ocmconfig"
  cat > "$order_good_cfg" <<YAML
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: CommonTransportFormat/v1
          filePath: "${CTF}"
          accessMode: readonly
        componentNamePattern: "github.com/lioramilbaum/**"
      - repository:
          type: CommonTransportFormat/v1
          filePath: "$tmp/empty-ctf"
          accessMode: readonly
        componentNamePattern: "github.com/**"
YAML
  local result
  result="$("$OCM" get cv "ctf::${consumer_ctf}//example.com/resolver-demo/consumer:1.0.0" \
    --recursive --config "$order_good_cfg" -o json)"
  local names
  names="$(printf '%s' "$result" | jq -r '.[].component.name' | sort | paste -sd, -)"
  assert_eq "$names" "example.com/resolver-demo/consumer,github.com/lioramilbaum/application" "resolved components in good order" || return 1
}

test_resource_access_types() {
  local tmp="$1"
  _build
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>/dev/null)"

  local a relation access img name
  for a in amd64 arm64; do
    relation=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .relation')
    assert_eq "$relation" "external" "$a image relation" || return 1
    access=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .access.type')
    assert_eq "$access" "OCIImage/v1" "$a image access type" || return 1
    img=$(echo "$cv_json" | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .access.imageReference')
    [[ "$img" == docker.io/* ]] || { echo "  $a image not referenced on docker.io: $img" >&2; return 1; }
  done

  for name in hello-world-manifests hello-world-localization hello-world-sbom deploy-bundle; do
    relation=$(echo "$cv_json" | jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .relation')
    assert_eq "$relation" "local" "$name relation" || return 1
    access=$(echo "$cv_json" | jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .access.type')
    assert_eq "$access" "LocalBlob/v1" "$name access type" || return 1
  done

  access=$(echo "$cv_json" | jq -r '.[0].component.sources[] | select(.name=="application-source") | .access.type')
  assert_eq "$access" "GitHub/v1" "source access type" || return 1
}

test_readme_documents_resource_access_types() {
  # awk rather than sed/head: BSD (macOS) sed and head reject the GNU-only forms
  local section
  section="$(awk '/^## Resource repositories/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Resource repositories' section" >&2; return 1; }
  assert_contains "$section" "OCIImage/v1" || return 1
  assert_contains "$section" "LocalBlob/v1" || return 1
  assert_contains "$section" "GitHub/v1" || return 1
  assert_contains "$section" "--copy-resources" || return 1
  assert_contains "$section" "--upload-as ociArtifact" || return 1
}

test_publish_copies_resources_as_oci_artifacts() {
  local tmp="$1" mode args
  mkdir -p "$tmp/cred" "$tmp/disc"
  _run_publish_stubbed "$tmp/cred" OCM_REGISTRY_USERNAME=demo-user OCM_REGISTRY_PASSWORD=demo-secret >/dev/null || return 1
  _run_publish_stubbed "$tmp/disc" >/dev/null || return 1

  for mode in cred disc; do
    args="$(cat "$tmp/$mode/ocm-args.log")"
    assert_contains "$args" "--copy-resources" || { echo "  $mode mode: --copy-resources missing" >&2; return 1; }
    assert_contains "$args" "--upload-as ociArtifact" || { echo "  $mode mode: --upload-as ociArtifact missing" >&2; return 1; }
  done
}

test_transfer_without_copy_resources_keeps_external_reference() {
  local tmp="$1" plan img_type fetches
  _build
  plan="$(_transfer_plan "ctf::$tmp/target")" || return 1

  # A zero fetch count is only meaningful if the plan actually has transformations
  local n_transforms
  n_transforms="$(printf '%s' "$plan" | jq '.transformations | length')"
  [[ "$n_transforms" -gt 0 ]] || { echo "  dry-run plan must contain at least one transformation" >&2; return 1; }

  img_type="$(echo "$plan" | jq -r '[.environment[].component.resources[] | select(.name=="hello-world-image") | .access.type] | unique | join(",")')"
  assert_eq "$img_type" "OCIImage/v1" "image access type after plain transfer" || return 1

  fetches="$(echo "$plan" | jq '[.transformations[] | select(.type=="GetOCIArtifact/v1alpha1")] | length')"
  assert_eq "$fetches" "0" "external image not downloaded" || return 1

  [[ ! -e "$tmp/target" ]] || { echo "  dry run must not create the target" >&2; return 1; }
}

test_transfer_copy_resources_inlines_image_as_local_blob() {
  local tmp="$1" plan fetched added
  _build
  plan="$(_transfer_plan "ctf::$tmp/target" --copy-resources)" || return 1

  fetched="$(echo "$plan" | jq -r '[.transformations[] | select(.type=="GetOCIArtifact/v1alpha1") | .spec.resource.name] | join(",")')"
  assert_eq "$fetched" "hello-world-image,hello-world-image" "only the external images are downloaded" || return 1

  # The CTF add transform's spec holds unresolved templates, so match on its label
  added="$(echo "$plan" | jq '[.transformations[] | select(.type=="CTFAddLocalResource/v1alpha1") | select(.label | test("hello-world-image"))] | length')"
  assert_eq "$added" "2" "one LocalBlob per architecture written to the CTF" || return 1
}

test_transfer_copy_resources_uploads_oci_artifact() {
  local tmp="$1" plan ref target_type mismatched n_artifacts
  _build
  plan="$(_transfer_plan "oci::http://localhost:5001" --copy-resources --upload-as ociArtifact)" || return 1

  # In OCM ≥0.19 imageReference is a CEL template with the target URL embedded as a
  # map-literal key ("baseUrl": "http://localhost:5001"), so we match on the host only.
  # One TransferOCIArtifact per architecture variant
  n_artifacts="$(echo "$plan" | jq '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1")] | length')"
  assert_eq "$n_artifacts" "2" "one OCI artifact transfer per architecture" || return 1

  local bad_refs
  bad_refs="$(echo "$plan" | jq '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.imageReference | select(contains("http://localhost:5001") | not)] | length')"
  assert_eq "$bad_refs" "0" "all target imageReferences contain http://localhost:5001" || return 1
  ref="$(echo "$plan" | jq -r '.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.imageReference')"
  assert_not_contains "$ref" "@sha256:" || return 1

  target_type="$(echo "$plan" | jq -r '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.type] | unique | join(",")')"
  assert_eq "$target_type" "ociArtifact/v1" "target access type" || return 1

  mismatched="$(echo "$plan" | jq '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | select(.spec.targetResource.digest.value != .spec.resource.digest.value)] | length')"
  assert_eq "$mismatched" "0" "digest preserved across transfer" || return 1
}

test_transfer_plan_lists_expected_operations() {
  local tmp="$1" plan_file output
  _build
  plan_file="$tmp/transfer-plan.json"
  output="$(env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_PLAN_FILE="$plan_file" OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null 2>&1)" || return 1
  [[ -f "$plan_file" ]] || { echo "  transfer-plan.json not written" >&2; return 1; }

  local types
  types="$(jq -r '[.transformations[].type] | unique | sort | .[]' "$plan_file")"
  assert_contains "$types" "TransferOCIArtifact/v1alpha1" || return 1
  assert_contains "$types" "OCIAddLocalResource/v1alpha1" || return 1
  assert_contains "$types" "OCIAddComponentVersion/v1alpha1" || return 1
  assert_not_contains "$types" "GetOCIArtifact/v1alpha1" || return 1

  local n_image_transfers
  n_image_transfers="$(jq '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1")] | length' "$plan_file")"
  assert_eq "$n_image_transfers" "2" "one TransferOCIArtifact per arch variant" || return 1

  local labels
  labels="$(jq -r '.transformations[].label // ""' "$plan_file")"
  assert_not_contains "$labels" "application-source" || return 1

  assert_contains "$output" "TransferOCIArtifact" || return 1
  assert_contains "$output" "TRANSFER_SPEC" || return 1
}

test_transfer_plan_replay_preserves_signature() {
  local tmp="$1" plan_file keep_cfg
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  # reference-uploader config: keep hello-world-image by reference (offline-safe)
  keep_cfg="$tmp/keep-images.ocmconfig"
  cat > "$keep_cfg" <<'YAML'
type: generic.config.ocm.software/v1
configurations:
  - type: reference.uploader.transfer.config.ocm.software/v1alpha1
    match: resource.name == "hello-world-image"
YAML

  plan_file="$tmp/replay-plan.json"
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_PLAN_FILE="$plan_file" TRANSFER_CONFIG="$keep_cfg" \
    OCM_REPO="ctf::$tmp/target" \
    bash "$ROOT/scripts/publish.sh" </dev/null >/dev/null || return 1

  # target must not exist yet (dry run)
  [[ ! -d "$tmp/target" ]] || { echo "  dry run created target" >&2; return 1; }

  # no GetOCIArtifact steps: images kept by reference
  local n_get
  n_get="$(jq '[.transformations[] | select(.type=="GetOCIArtifact/v1alpha1")] | length' "$plan_file")"
  assert_eq "$n_get" "0" "reference uploader suppresses GetOCIArtifact steps" || return 1

  # replay: publish to a CTF using the saved plan
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_SPEC="$plan_file" OCM_REPO="ctf::$tmp/target" \
    bash "$ROOT/scripts/publish.sh" </dev/null >/dev/null || return 1

  # verify the transferred component
  CTF="$tmp/target" bash "$ROOT/scripts/verify.sh" >/dev/null || \
    { echo "  verify failed after plan replay" >&2; return 1; }

  # The plan is a routing graph; OCM reads the actual descriptor from the source CTF
  # during replay, so editing the plan JSON does not affect what gets signed or written.
  # Signature protection is demonstrated by the clean verify above.
}

test_publish_replays_transfer_spec() {
  local tmp="$1" spec_file out
  _build
  spec_file="$tmp/spec.json"
  echo '{}' > "$spec_file"  # placeholder; only checking CLI args

  # TRANSFER_SPEC and TRANSFER_PLAN together must fail
  out="$(env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_SPEC="$spec_file" OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null 2>&1)" && \
    { echo "  expected failure for TRANSFER_PLAN+TRANSFER_SPEC" >&2; return 1; }
  assert_contains "$out" "mutually exclusive" || return 1

  # Missing spec file must fail before ocm runs
  out="$(env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_SPEC="$tmp/nonexistent.json" OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null 2>&1)" && \
    { echo "  expected failure for missing TRANSFER_SPEC" >&2; return 1; }
  assert_contains "$out" "not found" || return 1
}

test_transfer_config_routes_images_per_architecture() {
  local tmp="$1" plan_file plan_with plan_without
  _build

  plan_with="$tmp/plan-with-config.json"
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_PLAN_FILE="$plan_with" \
    TRANSFER_CONFIG="$ROOT/transfer.ocmconfig" \
    OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null >/dev/null || return 1

  # With config: image references contain architecture
  local refs_with
  refs_with="$(jq -r '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.imageReference] | .[]' "$plan_with")"
  assert_contains "$refs_with" "architecture" || return 1

  plan_without="$tmp/plan-without-config.json"
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_PLAN_FILE="$plan_without" \
    OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null >/dev/null || return 1

  # Without config: image references do not contain architecture
  local refs_without
  refs_without="$(jq -r '[.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.imageReference] | .[]' "$plan_without")"
  assert_not_contains "$refs_without" "architecture" || return 1
}

test_readme_documents_transfer_and_transport() {
  local tmp="$1" section consuming_section
  section="$(awk '/^## Transfer and transport/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  ## Transfer and transport section missing" >&2; return 1; }

  assert_contains "$section" "ocm.software/docs/concepts/transfer-and-transport" || return 1
  assert_contains "$section" "ocm transfer cv" || return 1
  assert_contains "$section" "--dry-run" || return 1
  assert_contains "$section" "--transfer-spec" || return 1
  assert_contains "$section" "make transfer-plan" || return 1
  assert_contains "$section" "TRANSFER_SPEC" || return 1
  assert_contains "$section" "TRANSFER_CONFIG" || return 1
  assert_contains "$section" "TransformationGraphDefinition" || return 1
  assert_contains "$section" "oci.uploader.transfer.config.ocm.software/v1alpha1" || return 1
  assert_contains "$section" "localblob.uploader.transfer.config.ocm.software/v1alpha1" || return 1
  assert_contains "$section" "extraIdentity.architecture" || return 1
  assert_contains "$section" "digest mismatch" || return 1
  assert_contains "$section" "(#signing-and-verification)" || return 1
  assert_contains "$section" "(#consuming-the-component)" || return 1
  assert_not_contains "$section" "ocm transfer plan" || return 1

  _build
  local plan_file types
  plan_file="$tmp/doc-check-plan.json"
  env -u OCM_REGISTRY_USERNAME -u OCM_REGISTRY_PASSWORD \
    TRANSFER_PLAN=1 TRANSFER_PLAN_FILE="$plan_file" OCM_REPO="oci::http://localhost:5001" \
    bash "$ROOT/scripts/publish.sh" </dev/null >/dev/null || return 1
  while IFS= read -r t; do
    [[ "$t" == "FileCleanup/v1alpha1" ]] && continue
    assert_contains "$section" "$t" || return 1
  done < <(jq -r '[.transformations[].type] | unique | .[]' "$plan_file")

  consuming_section="$(awk '/^## Consuming the component/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  assert_contains "$consuming_section" "(#transfer-and-transport)" || return 1
}

test_ctf_layout_is_canonical() {
  local tmp="$1" digest manifest d name version
  _build

  # Root must contain exactly artifact-index.json and blobs/
  # shellcheck disable=SC2012
  assert_eq "$(ls -A "$CTF" | sort | paste -sd, -)" "artifact-index.json,blobs" "ctf root entries" || return 1
  assert_eq "$(jq -r .schemaVersion "$CTF/artifact-index.json")" "1" "index schemaVersion" || return 1

  # Find the manifest for this component version by repository+tag (not by array position,
  # since sign.sh adds an extra untagged entry).
  digest="$(jq -r --arg r "component-descriptors/$ROOT_COMPONENT" --arg t "$VERSION" \
    '.artifacts[] | select(.repository==$r and .tag==$t) | .digest' \
    "$CTF/artifact-index.json")"
  [[ -n "$digest" ]] || { echo "  no manifest digest for $ROOT_COMPONENT:$VERSION"; return 1; }
  [[ "$digest" == sha256:* ]] || { echo "  digest does not start with sha256:"; return 1; }

  manifest="$CTF/blobs/${digest/:/.}"
  [[ -f "$manifest" ]] || { echo "  manifest blob missing: $manifest"; return 1; }
  assert_eq "$(jq -r .artifactType "$manifest")" \
    "application/vnd.ocm.software.component-descriptor.v2" "manifest artifactType" || return 1

  # Every blob referenced by the manifest must exist
  while IFS= read -r d; do
    [[ -f "$CTF/blobs/${d/:/.}" ]] || { echo "  referenced blob missing: $d"; return 1; }
  done < <(jq -r '.config.digest, .layers[].digest' "$manifest")

  # Descriptor layer contains the correct component name and version
  local desc_digest
  desc_digest="$(jq -r '.layers[] | select(.mediaType=="application/vnd.ocm.software.component-descriptor.v2+json") | .digest' "$manifest")"
  [[ -n "$desc_digest" ]] || { echo "  no descriptor layer digest"; return 1; }
  name="$(jq -r .component.name "$CTF/blobs/${desc_digest/:/.}")"
  version="$(jq -r .component.version "$CTF/blobs/${desc_digest/:/.}")"
  assert_eq "$name" "$ROOT_COMPONENT" "component name in descriptor" || return 1
  assert_eq "$version" "$VERSION" "component version in descriptor" || return 1

  # Every blob file is content-addressed (filename == sha256 of content)
  local f actual expected
  while IFS= read -r f; do
    actual="$(sha256 "$f")"
    expected="${f##*/sha256.}"
    assert_eq "$actual" "$expected" "content-address of $(basename "$f")" || return 1
  done < <(find "$CTF/blobs" -maxdepth 1 -type f)
}

test_ctf_archive_is_portable_and_signed() {
  local tmp="$1" archive target
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  archive="$tmp/application.ctf.tar"
  tar -C "$CTF" -cf "$archive" artifact-index.json blobs

  # Delete the original CTF to prove the archive is self-contained
  rm -rf "$CTF"

  # Signature survives in the archive
  CTF="$archive" bash "$ROOT/scripts/verify.sh" >/dev/null || \
    { echo "  verify.sh failed on CTF archive"; return 1; }

  # This component has no references; the assertion verifies OCM does not spuriously require
  # resolvers for a leaf component (any single-component CTF trivially satisfies canonicality).
  local names
  names="$("$OCM" get cv "ctf::$archive//${ROOT_COMPONENT}:${VERSION}" \
    --recursive --config "$(_empty_ocmconfig "$tmp")" -o json \
    | jq -r '.[].component.name' | sort | paste -sd, -)"
  assert_eq "$names" "$ROOT_COMPONENT" "canonical: all components present without resolvers" || return 1

  # Signature survives CTF-to-CTF transfer
  target="$tmp/target-ctf"
  "$OCM" transfer cv "ctf::$archive//${ROOT_COMPONENT}:${VERSION}" "ctf::$target" \
    >/dev/null 2>&1 || { echo "  ctf-to-ctf transfer failed"; return 1; }
  CTF="$target" bash "$ROOT/scripts/verify.sh" >/dev/null || \
    { echo "  verify.sh failed on transferred CTF"; return 1; }
}

test_readme_documents_canonical_component_repositories() {
  local tmp="$1" section
  section="$(awk '/^## Canonical component repositories/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no ## Canonical component repositories section"; return 1; }
  assert_contains "$section" "Common Transport Format" || return 1
  assert_contains "$section" "build/ctf/" || return 1
  assert_contains "$section" "artifact-index.json" || return 1
  assert_contains "$section" "blobs/" || return 1
  assert_contains "$section" "ctf::" || return 1
  assert_contains "$section" "oci::" || return 1
  assert_contains "$section" "--recursive" || return 1
}

test_readme_documents_kubernetes_controller() {
  local tmp="$1" section
  section="$(awk '/^## Kubernetes controller/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Kubernetes controller' section" >&2; return 1; }
  assert_contains "$section" "apiVersion: delivery.ocm.software/v1alpha1" || return 1
  assert_contains "$section" "kind: Repository" || return 1
  assert_contains "$section" "kind: Component" || return 1
  assert_not_contains "$section" "kind: ComponentVersion" || return 1
  assert_contains "$section" "type: OCIRegistry" || return 1
  assert_contains "$section" "baseUrl: ghcr.io/lioramilbaum/ocm" || return 1
  assert_contains "$section" "component: $ROOT_COMPONENT" || return 1
  assert_contains "$section" "repositoryRef:" || return 1
  assert_contains "$section" "semver:" || return 1
  assert_contains "$section" "interval:" || return 1
  assert_contains "$section" "https://ocm.software/docs/concepts/kubernetes-controllers/" || return 1
  assert_contains "$section" "bindings/go/kubernetes/controller" || return 1
}

test_readme_documents_kubernetes_deployer() {
  local tmp="$1" section
  section="$(awk '/^## Kubernetes deployer/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Kubernetes deployer' section" >&2; return 1; }
  assert_contains "$section" "apiVersion: delivery.ocm.software/v1alpha1" || return 1
  assert_contains "$section" "kind: Resource" || return 1
  assert_contains "$section" "kind: NamespacedDeployer" || return 1
  assert_contains "$section" "componentRef: {name: application}" || return 1
  assert_contains "$section" "byReference: {resource: {name: hello-world-manifests}}" || return 1
  assert_contains "$section" "resourceRef: {name: hello-world-manifests}" || return 1
  assert_contains "$section" "serviceAccountName:" || return 1
  assert_contains "$section" "deploy.sh" || return 1
  assert_contains "$section" "manifests.sh" || return 1
  assert_contains "$section" "HELLO_WORLD_IMAGE" || return 1
  assert_contains "$section" "https://ocm.software/docs/concepts/kubernetes-deployer/" || return 1
  assert_contains "$section" "bindings/go/kubernetes/controller" || return 1
  assert_not_contains "$section" "kind: Localization" || return 1
  assert_not_contains "$section" "kind: ComponentVersion" || return 1
}

test_builtin_plugins_serve_component_types() {
  local tmp="$1" types expected
  _build
  mkdir -p "$tmp/plugins"
  types="$("$OCM" --plugin-directory "$tmp/plugins" --loglevel debug \
    get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>"$tmp/plugins.log" \
    | jq -r '[.[0].component.resources[].access.type, .[0].component.sources[].access.type] | unique | join(",")')"
  expected="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json \
    | jq -r '[.[0].component.resources[].access.type, .[0].component.sources[].access.type] | unique | join(",")')"
  assert_eq "$types" "$expected" "access types with no external plugins" || return 1
  # "no plugins found" is from bindings/go/plugin/manager/manager.go — update if OCM rewording occurs
  assert_contains "$(cat "$tmp/plugins.log")" "no plugins found" || return 1

  "$OCM" --plugin-directory "$tmp/plugins" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity name=hello-world-manifests --output "$tmp/manifests.yaml" >/dev/null || return 1
  cmp "$tmp/manifests.yaml" "$ROOT/components/hello-world/manifests.yaml" || \
    { echo "  manifests download differs without plugins" >&2; return 1; }
}

test_readme_documents_plugin_system() {
  local tmp="$1" section t
  section="$(awk '/^## Plugin system/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Plugin system' section" >&2; return 1; }
  assert_contains "$section" "https://ocm.software/docs/concepts/plugin-system/" || return 1
  assert_contains "$section" "bindings/go/plugin" || return 1
  assert_contains "$section" "--plugin-directory" || return 1
  assert_contains "$section" ".config/ocm/plugins" || return 1
  assert_contains "$section" "capabilities" || return 1
  assert_contains "$section" "built-in plugin" || return 1
  assert_contains "$section" "CommonTransportFormat/v1" || return 1
  assert_contains "$section" "Dir/v1" || return 1
  assert_contains "$section" "RSA/v1alpha1" || return 1
  assert_contains "$section" "ocm download plugin" || return 1
  assert_not_contains "$section" "deployer plugin" || return 1

  _build
  for t in $("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json \
    | jq -r '[.[0].component.resources[].access.type, .[0].component.sources[].access.type] | unique[]'); do
    assert_contains "$section" "$t" || return 1
  done
}

# _tamper_descriptor <ctf_dir> <version> <jq_filter> <out_dir>
# Copies <ctf_dir> to <out_dir>, applies <jq_filter> to the component descriptor of
# <version>, and re-addresses all blobs so the CTF remains consistent.
_tamper_descriptor() {
  local src="$1" ver="$2" filter="$3" out="$4"
  cp -R "$src" "$out"
  local idx="$out/artifact-index.json"
  local mdigest; mdigest="$(jq -r --arg t "$ver" '.artifacts[] | select(.tag==$t) | .digest' "$idx")"
  local mpath="$out/blobs/${mdigest/:/.}"
  local cfgdigest; cfgdigest="$(jq -r '.config.digest' "$mpath")"
  local cfgpath="$out/blobs/${cfgdigest/:/.}"
  local old; old="$(jq -r '.componentDescriptorLayer.digest' "$cfgpath")"
  local oldpath="$out/blobs/${old/:/.}"

  jq -c "$filter" "$oldpath" > "$out/new"
  local d size; d="sha256:$(sha256 "$out/new")"; size="$(wc -c < "$out/new" | tr -d ' ')"
  [[ "$d" != "$old" ]] || { echo "  _tamper_descriptor: filter changed nothing: $filter" >&2; return 1; }
  mv "$out/new" "$out/blobs/${d/:/.}"

  jq -c --arg d "$d" --argjson n "$size" \
    '.componentDescriptorLayer.digest=$d | .componentDescriptorLayer.size=$n' "$cfgpath" > "$out/new"
  local cd csize; cd="sha256:$(sha256 "$out/new")"; csize="$(wc -c < "$out/new" | tr -d ' ')"
  mv "$out/new" "$out/blobs/${cd/:/.}"

  jq -c --arg d "$d" --argjson n "$size" --arg cd "$cd" --argjson cn "$csize" --arg old "$old" \
    '.config.digest=$cd | .config.size=$cn | (.layers[] | select(.digest==$old)) |= (.digest=$d | .size=$n)' \
    "$mpath" > "$out/new"
  local md; md="sha256:$(sha256 "$out/new")"
  mv "$out/new" "$out/blobs/${md/:/.}"

  jq --arg t "$ver" --arg md "$md" \
    '(.artifacts[] | select(.tag==$t) | .digest) = $md' "$idx" > "$out/new"
  mv "$out/new" "$idx"
}

test_signature_covers_normalized_descriptor() {
  local tmp="$1" expect filter n=0 out work
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  assert_eq \
    "$("$OCM" get cv "$(cv_ref)" -o json | jq '[.[0].component.labels[] | select(.signing == true)] | length')" \
    "0" "signed labels" || return 1

  while IFS=$'\t' read -r expect filter; do
    n=$((n + 1)); work="$tmp/tampered-$n"
    _tamper_descriptor "$CTF" "$VERSION" "$filter" "$work" || return 1
    if [[ "$expect" == pass ]]; then
      CTF="$work" bash "$ROOT/scripts/verify.sh" </dev/null >/dev/null 2>&1 \
        || { echo "  verify rejected unsigned change ($n): $filter" >&2; return 1; }
    else
      out="$(CTF="$work" bash "$ROOT/scripts/verify.sh" </dev/null 2>&1)" \
        && { echo "  verify accepted signed change ($n): $filter" >&2; return 1; }
      assert_contains "$out" "digest mismatch" || return 1
    fi
  done <<'TABLE'
pass	(.component.labels[] | select(.name=="application.lioramilbaum.github.com/tier") | .value) = "tampered"
pass	(.component.sources[0].access.commit) = "fedcba9876543210fedcba9876543210fedcba98"
pass	(.component.resources[] | select(.name=="hello-world-image") | .access.imageReference) |= sub("^docker.io/"; "evil.example/")
fail	(.component.labels[] | select(.name=="application.lioramilbaum.github.com/tier") | .signing) = true
fail	(.component.provider) = "github.com/someoneelse"
fail	(.component.resources[] | select(.name=="hello-world-manifests") | .digest.value) = "0000000000000000000000000000000000000000000000000000000000000000"
TABLE
}

test_readme_documents_signing_and_verification() {
  local tmp="$1" section t algo norm hash
  section="$(awk '/^## Signing and verification/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Signing and verification' section" >&2; return 1; }
  assert_contains "$section" "https://ocm.software/docs/concepts/signing-and-verification/" || return 1
  assert_contains "$section" "jsonNormalisation/v4alpha1" || return 1
  assert_contains "$section" "SHA-256" || return 1
  assert_contains "$section" "RSASSA-PSS" || return 1
  assert_contains "$section" "genericBlobDigest/v1" || return 1
  assert_contains "$section" "signing: true" || return 1
  assert_contains "$section" "application.lioramilbaum.github.com/tier" || return 1
  assert_contains "$section" "repositoryContexts" || return 1
  assert_contains "$section" "access" || return 1
  assert_contains "$section" "commit" || return 1
  assert_contains "$section" "make verify" || return 1
  assert_contains "$section" "Sigstore" || return 1
  assert_contains "$section" "SigstoreVerificationConfiguration/v1alpha1" || return 1
  assert_contains "$section" "RSA/v1alpha1" || return 1
  assert_not_contains "$section" 'jsonNormalisation/v1`' || return 1

  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null
  norm="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].signatures[0].digest.normalisationAlgorithm')"
  hash="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].signatures[0].digest.hashAlgorithm')"
  algo="$("$OCM" get cv "$(cv_ref)" -o json | jq -r '.[0].signatures[0].signature.algorithm')"
  assert_contains "$section" "$norm" || return 1
  assert_contains "$section" "$hash" || return 1
  assert_contains "$section" "$algo" || return 1

  while IFS= read -r t; do
    assert_contains "$section" "$t" || return 1
  done < <("$OCM" get cv "$(cv_ref)" -o json \
    | jq -r '[.[0].component.labels[] | select(.signing != true) | .name] | unique[]')
}

test_component_identity_selects_artifacts() {
  local tmp="$1" cv_json out
  _build
  cv_json="$("$OCM" get cv "$(cv_ref)" -o json)"

  local re='^[a-z][-a-z0-9]*([.][a-z][-a-z0-9]*)*[.][a-z]{2,}(/[a-z][-a-z0-9_]*([.][a-z][-a-z0-9_]*)*)+$'
  [[ "$(jq -r '.[0].component.name' <<<"$cv_json")" =~ $re ]] \
    || { echo "  component name does not match regex" >&2; return 1; }

  local count; count="$(jq '[.[0].component.resources[] | {name,version,extraIdentity}] | unique | length' <<<"$cv_json")"
  local total; total="$(jq '[.[0].component.resources[]] | length' <<<"$cv_json")"
  assert_eq "$count" "$total" "all resource identities are unique" || return 1

  "$OCM" download resource "$(cv_ref)" --identity "name=hello-world-manifests" \
    --output "$tmp/m1.yaml" >/dev/null || return 1
  cmp "$tmp/m1.yaml" "$ROOT/components/hello-world/manifests.yaml" \
    || { echo "  subset-match download differs" >&2; return 1; }

  "$OCM" download resource "$(cv_ref)" --identity "name=hello-world-manifests,version=$VERSION" \
    --output "$tmp/m2.yaml" >/dev/null || return 1
  cmp "$tmp/m2.yaml" "$ROOT/components/hello-world/manifests.yaml" \
    || { echo "  exact-match download differs" >&2; return 1; }

  out="$("$OCM" download resource "$(cv_ref)" --identity "version=$VERSION" \
    --output "$tmp/bad.yaml" 2>&1)" \
    && { echo "  version-only identity should fail" >&2; return 1; }
  assert_contains "$out" "got 7" || return 1

  out="$("$OCM" download resource "$(cv_ref)" \
    --identity "name=hello-world-manifests,version=9.9.9" \
    --output "$tmp/bad2.yaml" 2>&1)" \
    && { echo "  wrong-version identity should fail" >&2; return 1; }
  assert_contains "$out" "got 0" || return 1

  out="$("$OCM" download resource "$(cv_ref)" --identity "name=hello-world-image" \
    --output "$tmp/bad3.tar" 2>&1)" \
    && { echo "  name-only image identity should fail" >&2; return 1; }
  assert_contains "$out" "got 2" || return 1

  out="$("$OCM" download resource "$(cv_ref)" --identity "name=hello-world-image,architecture=s390x" \
    --output "$tmp/bad4.tar" 2>&1)" \
    && { echo "  unknown architecture identity should fail" >&2; return 1; }
  assert_contains "$out" "got 0" || return 1

  "$OCM" download resource "$(cv_ref)" --identity "name=hello-world-image,architecture=amd64" \
    --output "$tmp/img-amd64.tar" --extraction-policy disable >/dev/null || return 1
  [[ -s "$tmp/img-amd64.tar" ]] || { echo "  amd64 image download is empty" >&2; return 1; }

  assert_fails "$OCM" get cv "ctf::$CTF//${ROOT_COMPONENT}:9.9.9" -o json || return 1

  local versions; versions="$("$OCM" get cv "ctf::$CTF//${ROOT_COMPONENT}" -o json \
    | jq -r '.[].component.version')"
  assert_contains "$versions" "$VERSION" || return 1
}

test_component_identity_rules_enforced() {
  local tmp="$1" cfg n=0 out
  cfg="$(_empty_ocmconfig "$tmp")"
  printf 'a' > "$tmp/a.txt"
  printf 'b' > "$tmp/b.txt"

  while IFS='|' read -r cname cver; do
    n=$((n+1))
    cat > "$tmp/c$n.yaml" <<YAML
components:
  - name: $cname
    version: $cver
    provider: {name: test}
    resources:
      - name: ap
        version: $cver
        type: blob
        input: {type: file, path: ./a.txt}
YAML
    out="$("$OCM" add cv --repository "ctf::$tmp/bad$n" \
      --constructor "$tmp/c$n.yaml" --config "$cfg" 2>&1)" \
      && { echo "  expected failure for name=$cname version=$cver" >&2; return 1; }
    # error wording varies across OCM versions; just confirm the command rejected
    assert_contains "$out" "Error" || return 1
  done <<'TABLE'
example.com/Demo|1.0.0
demo|1.0.0
example.com|1.0.0
example.com/identity-demo|latest
TABLE

  cat > "$tmp/dup.yaml" <<'YAML'
components:
  - name: example.com/identity-demo
    version: 1.0.0
    provider: {name: test}
    resources:
      - name: ap
        version: 1.0.0
        type: blob
        input: {type: file, path: ./a.txt}
      - name: ap
        version: 1.0.0
        type: ociImage
        input: {type: file, path: ./b.txt}
YAML
  out="$("$OCM" add cv --repository "ctf::$tmp/dup" \
    --constructor "$tmp/dup.yaml" --config "$cfg" 2>&1)" \
    && { echo "  expected duplicate identity failure" >&2; return 1; }
  assert_contains "$out" "duplicate resource identities" || return 1

  cat > "$tmp/variants.yaml" <<'YAML'
components:
  - name: example.com/identity-demo
    version: 1.0.0
    provider: {name: test}
    resources:
      - name: ap
        version: 1.0.0
        extraIdentity: {architecture: amd64}
        type: blob
        input: {type: file, path: ./a.txt}
      - name: ap
        version: 1.0.0
        extraIdentity: {architecture: arm64}
        type: blob
        input: {type: file, path: ./b.txt}
YAML
  "$OCM" add cv --repository "ctf::$tmp/variants" \
    --constructor "$tmp/variants.yaml" --config "$cfg" >/dev/null || return 1

  out="$("$OCM" download resource "ctf::$tmp/variants//example.com/identity-demo:1.0.0" \
    --identity "name=ap" --output "$tmp/ap-any.txt" 2>&1)" \
    && { echo "  ambiguous name-only identity should fail" >&2; return 1; }
  assert_contains "$out" "got 2" || return 1

  "$OCM" download resource "ctf::$tmp/variants//example.com/identity-demo:1.0.0" \
    --identity "name=ap,architecture=arm64" --output "$tmp/ap-arm64.txt" >/dev/null || return 1
  assert_eq "$(cat "$tmp/ap-arm64.txt")" "b" "arm64 variant content" || return 1

  out="$("$OCM" download resource "ctf::$tmp/variants//example.com/identity-demo:1.0.0" \
    --identity "name=ap,architecture=s390x" --output "$tmp/ap-s390x.txt" 2>&1)" \
    && { echo "  missing architecture should fail" >&2; return 1; }
  assert_contains "$out" "got 0" || return 1
}

test_manifests_selects_target_arch_variant() {
  local tmp="$1" out a digest other_digest
  _build
  for a in amd64 arm64; do
    TARGET_ARCH="$a" SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" >/dev/null || return 1
    digest="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>/dev/null \
      | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$a) | .digest.value')"
    other_digest="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json 2>/dev/null \
      | jq -r --arg a "$a" '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture!=$a) | .digest.value')"
    assert_contains "$(cat "$tmp/deploy/hello-world.yaml")" "@sha256:$digest" \
      || { echo "  manifest does not contain the $a image digest" >&2; return 1; }
    assert_not_contains "$(cat "$tmp/deploy/hello-world.yaml")" "@sha256:$other_digest" \
      || { echo "  manifest contains the other-architecture digest for TARGET_ARCH=$a" >&2; return 1; }
  done

  out="$(TARGET_ARCH=s390x SKIP_VERIFY=1 bash "$ROOT/scripts/manifests.sh" 2>&1)" \
    && { echo "  s390x should fail" >&2; return 1; }
  assert_contains "$out" "s390x" || return 1
  assert_contains "$out" "got 0" || return 1
}

test_readme_documents_component_identity() {
  local tmp="$1" section tree_section consuming_section n v identity
  section="$(awk '/^## Component identity/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README has no '## Component identity' section" >&2; return 1; }

  assert_contains "$section" "https://ocm.software/docs/concepts/component-identity/" || return 1
  assert_contains "$section" "$ROOT_COMPONENT" || return 1
  assert_contains "$section" 'a-z][-a-z0-9]*' || return 1
  assert_contains "$section" "name:version" || return 1
  assert_contains "$section" "OCM_COMPONENT_REPO" || return 1
  assert_contains "$section" "extraIdentity" || return 1
  assert_contains "$section" "--identity" || return 1
  assert_contains "$section" "duplicate resource identities" || return 1
  assert_contains "$section" "expected exactly one resource candidate" || return 1
  assert_contains "$section" "consumer identity" || return 1
  assert_contains "$section" "(#credential-system)" || return 1
  assert_contains "$section" "(#signing-and-verification)" || return 1
  assert_not_contains "$section" "major and minor" || return 1
  assert_not_contains "$section" "None uses \`extraIdentity\`" || return 1
  assert_not_contains "$section" "would select" || return 1
  assert_contains "$section" "TARGET_ARCH" || return 1
  assert_contains "$section" "name=hello-world-image,architecture=amd64" || return 1
  assert_contains "$section" "Name coordinate" || return 1
  assert_contains "$section" "name coordinate" || return 1

  _build
  while IFS=$'\t' read -r n identity; do
    assert_contains "$section" "$identity" || return 1
    assert_contains "$section" "${ROOT_COMPONENT}:${VERSION}:resource/$n" || return 1
  done < <("$OCM" get cv "$(cv_ref)" -o json \
    | jq -r '.[0].component.resources[] | [.name, ("name=\(.name),version=\(.version)" + ([.extraIdentity // {} | to_entries[] | ",\(.key)=\(.value)"] | join("")))] | @tsv')

  while IFS= read -r n; do
    assert_contains "$section" "name=$n,version=$VERSION" || return 1
    assert_contains "$section" "${ROOT_COMPONENT}:${VERSION}:source/$n" || return 1
  done < <("$OCM" get cv "$(cv_ref)" -o json \
    | jq -r '.[0].component.sources[].name')

  tree_section="$(awk '/^## Component tree/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  assert_contains "$tree_section" "(#component-identity)" || return 1

  consuming_section="$(awk '/^## Consuming the component/{f=1; next} /^## /{f=0} f' "$ROOT/README.md")"
  assert_contains "$consuming_section" "(#component-identity)" || return 1
}

test_discovery_selects_image_variants() {
  local yaml="$ROOT/k8s/discovery.yaml"
  [[ -f "$yaml" ]] || { echo "  k8s/discovery.yaml not found" >&2; return 1; }
  assert_contains "$(cat "$yaml")" "apiVersion: delivery.ocm.software/v1alpha1" || return 1
  assert_contains "$(cat "$yaml")" "kind: Discovery" || return 1
  assert_contains "$(cat "$yaml")" "name: application" || return 1
  assert_contains "$(cat "$yaml")" "name: hello-world-image" || return 1

  _build

  local cv_json resources count
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  # Verify the component label matches the componentSelector
  local tier_label
  tier_label="$(echo "$cv_json" | jq -r '.[0].component.labels[] | select(.name=="application.lioramilbaum.github.com/tier") | .value')"
  [[ -n "$tier_label" ]] || { echo "  tier label not found in component descriptor" >&2; return 1; }
  assert_contains "$(cat "$yaml")" "application.lioramilbaum.github.com/tier: $tier_label" || return 1

  # matchIdentity name: hello-world-image should select exactly 2 resources (amd64 + arm64)
  resources="$(echo "$cv_json" | jq -c '[.[0].component.resources[] | select(.name=="hello-world-image")]')"
  count="$(echo "$resources" | jq length)"
  assert_eq "$count" "2" "expected 2 hello-world-image resources" || return 1

  # Architecture values must be amd64 and arm64
  local arch_values
  arch_values="$(echo "$resources" | jq -r '[.[] | .extraIdentity.architecture] | sort | join(",")')"
  assert_eq "$arch_values" "amd64,arm64" "unexpected architecture values" || return 1

  # Every byResources path must resolve to a non-null value on each selected resource
  # (guards against silent-omission: a typo in a path drops the field without error)
  local path null_count
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+[a-z]+:[[:space:]]+(resource\..+)$ ]]; then
      path="${BASH_REMATCH[1]#resource.}"
      null_count="$(echo "$resources" | jq --arg p "$path" '[.[] | getpath($p | split(".")) | select(. == null)] | length')"
      [[ "$null_count" -eq 0 ]] || { echo "  byResources path 'resource.$path' resolves to null on at least one resource" >&2; return 1; }
    fi
  done < <(awk '/byResources:/{f=1;next} /^    [^ ]/{f=0} f' "$yaml")
}

test_readme_documents_kubernetes_component_discovery() {
  local section
  section="$(awk '/^## Kubernetes component discovery/{f=1;next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README missing '## Kubernetes component discovery' section" >&2; return 1; }

  assert_contains "$section" "https://ocm.software/docs/concepts/kubernetes-component-discovery/" || return 1
  assert_contains "$section" "bindings/go/kubernetes/controller" || return 1
  assert_contains "$section" "kind: Discovery" || return 1
  assert_contains "$section" "componentRef:" || return 1
  assert_contains "$section" "status.extracted" || return 1
  assert_contains "$section" "status.components" || return 1
  assert_contains "$section" "observedGeneration" || return 1
  assert_contains "$section" "v0.15.0" || return 1
  assert_contains "$section" "manifests.sh" || return 1
  assert_contains "$section" "interval" || return 1

  assert_not_contains "$section" "kind: ComponentVersion" || return 1
  assert_not_contains "$section" "ComponentVersionSubscription" || return 1

  # Drift guard: the YAML block in the README must match k8s/discovery.yaml
  local readme_yaml disk_yaml
  readme_yaml="$(echo "$section" | awk '/^```yaml/{f=1;next} /^```/{f=0} f' | grep -v '^#')"
  disk_yaml="$(grep -v '^#' "$ROOT/k8s/discovery.yaml")"
  [[ "$readme_yaml" = "$disk_yaml" ]] || { echo "  README YAML block differs from k8s/discovery.yaml" >&2; return 1; }
}

test_ownership_records_owner() {
  local tmp="$1" ctf cv_json local_ref own_blob name ref tag
  local OWNERSHIP_COMPONENT="github.com/lioramilbaum/ownership-demo"
  ctf="$(_build_ownership "$tmp")"
  cv_json="$("$OCM" get cv "ctf::$ctf//$OWNERSHIP_COMPONENT:$VERSION" -o json)"

  # The ownership policy is a construction directive and is not persisted in the descriptor
  assert_not_contains "$cv_json" '"options"' || return 1

  local_ref="$(jq -r '.[0].component.resources[] | select(.name=="hello-world-site") | .access.localReference' <<<"$cv_json")"
  [[ "$local_ref" == sha256:* ]] || { echo "  no localReference for hello-world-site"; return 1; }
  own_blob="$ctf/blobs/$(_ownership_record_digest "$ctf" hello-world-site | sed 's/:/./')"
  [[ -f "$own_blob" ]] || { echo "  no ownership record for hello-world-site"; return 1; }

  assert_eq "$(jq -r .subject.digest "$own_blob")" "$local_ref" "subject digest" || return 1
  assert_eq "$(jq -r '.annotations["software.ocm.component.name"]' "$own_blob")" \
    "$OWNERSHIP_COMPONENT" "component name annotation" || return 1
  assert_eq "$(jq -r '.annotations["software.ocm.component.version"]' "$own_blob")" \
    "$VERSION" "component version annotation" || return 1
  assert_eq "$(jq -r '.annotations["software.ocm.artifact"] | fromjson | .kind' "$own_blob")" \
    "resource" "artifact kind annotation" || return 1
  assert_eq "$(jq -r '.annotations["software.ocm.artifact"] | fromjson | .identity.name' "$own_blob")" \
    "hello-world-site" "artifact identity annotation" || return 1

  # Resources without a policy, and raw blobs, must not leave a referrers tag behind
  for name in hello-world-site-untracked hello-world-manifests; do
    ref="$(jq -r --arg n "$name" '.[0].component.resources[] | select(.name==$n) | .access.localReference' <<<"$cv_json")"
    tag="${ref/:/-}"
    assert_eq "$(jq -r --arg t "$tag" '[.artifacts[] | select(.tag==$t)] | length' "$ctf/artifact-index.json")" \
      "0" "no referrers tag for $name" || return 1
  done
}

test_ownership_record_is_deterministic() {
  local tmp="$1" first second count
  OWNERSHIP_CTF="$tmp/ctf1" bash "$ROOT/scripts/ownership.sh" build >/dev/null
  OWNERSHIP_CTF="$tmp/ctf2" bash "$ROOT/scripts/ownership.sh" build >/dev/null

  first="$(_ownership_record_digest "$tmp/ctf1" hello-world-site)"
  second="$(_ownership_record_digest "$tmp/ctf2" hello-world-site)"
  [[ -n "$first" ]] || { echo "  no ownership record in first build"; return 1; }
  assert_eq "$second" "$first" "record digest across builds" || return 1

  # Re-adding into the same CTF with --component-version-conflict-policy replace must
  # converge to a single ownership record (idempotency), not duplicate it.
  OWNERSHIP_CTF="$tmp/ctf1" OCM_ADD_FLAGS="--component-version-conflict-policy replace" \
    bash "$ROOT/scripts/ownership.sh" readd >/dev/null
  count="$(_ownership_record_count "$tmp/ctf1")"
  assert_eq "$count" "1" "ownership records after replace" || return 1
}

test_ownership_survives_transfer() {
  local tmp="$1" ctf target source_record target_record out
  ctf="$(_build_ownership "$tmp")"
  target="$tmp/target"

  "$OCM" transfer cv "ctf::$ctf//github.com/lioramilbaum/ownership-demo:$VERSION" "ctf::$target" \
    >/dev/null || { echo "  ctf-to-ctf transfer failed"; return 1; }

  source_record="$(_ownership_record_digest "$ctf" hello-world-site)"
  target_record="$(_ownership_record_digest "$target" hello-world-site)"
  [[ -n "$source_record" ]] || { echo "  no ownership record in source CTF"; return 1; }
  assert_eq "$target_record" "$source_record" "record digest after transfer" || return 1

  out="$(OWNERSHIP_CTF="$target" bash "$ROOT/scripts/ownership.sh" trace)"
  assert_contains "$out" "hello-world-site" || return 1
  assert_contains "$out" "github.com/lioramilbaum/ownership-demo:$VERSION" || return 1
}

test_ownership_trace_reports_owner() {
  local tmp="$1" ctf out
  ctf="$(_build_ownership "$tmp")"
  out="$(OWNERSHIP_CTF="$ctf" bash "$ROOT/scripts/ownership.sh" trace)"

  grep -qF $'hello-world-site\t'"github.com/lioramilbaum/ownership-demo:$VERSION" <<<"$out" \
    || { echo "  expected hello-world-site owner line" >&2; return 1; }
  grep -qF $'hello-world-site-untracked\t-\tno ownership record' <<<"$out" \
    || { echo "  expected hello-world-site-untracked no-record line" >&2; return 1; }
  grep -qF $'hello-world-manifests\t-\tno ownership record (not an OCI manifest)' <<<"$out" \
    || { echo "  expected hello-world-manifests not-an-oci-manifest line" >&2; return 1; }
  assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "3" "trace line count" || return 1
}

test_readme_documents_ownership() {
  local section readme_yaml disk_yaml
  section="$(awk '/^## Ownership/{f=1;next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || { echo "  README missing '## Ownership' section" >&2; return 1; }

  assert_contains "$section" "https://ocm.software/docs/concepts/ownership/" || return 1
  assert_contains "$section" "https://ocm.software/docs/how-to/add-and-verify-ownership/" || return 1
  assert_contains "$section" "ownershipPolicy: Always" || return 1
  assert_contains "$section" "Never" || return 1
  assert_contains "$section" "application/vnd.ocm.software.ownership.v1+json" || return 1
  assert_contains "$section" "software.ocm.component.name" || return 1
  assert_contains "$section" "software.ocm.component.version" || return 1
  assert_contains "$section" "software.ocm.artifact" || return 1
  assert_contains "$section" "subject" || return 1
  assert_contains "$section" "sha256-" || return 1
  assert_contains "$section" "artifact-index.json" || return 1
  assert_contains "$section" "oras discover" || return 1
  assert_contains "$section" "make ownership" || return 1
  assert_contains "$section" "401" || return 1
  assert_contains "$section" "(#transfer-and-transport)" || return 1
  assert_contains "$section" "(#signing-and-verification)" || return 1

  assert_not_contains "$section" "ComponentVersion" || return 1

  # Drift guard: the YAML block in the README must match the constructor
  readme_yaml="$(echo "$section" | awk '/^```yaml/{f=1;next} /^```/{f=0} f' | grep -v '^#')"
  disk_yaml="$(grep -v '^#' "$ROOT/components/ownership/component-constructor.yaml")"
  [[ "$readme_yaml" = "$disk_yaml" ]] || { echo "  README YAML block differs from components/ownership/component-constructor.yaml" >&2; return 1; }
}

test_sbom_resource_metadata() {
  local tmp="$1"
  _build

  local cv_json sbom_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"
  sbom_json="$(echo "$cv_json" | jq '.[0].component.resources[] | select(.name=="hello-world-sbom")')"

  assert_eq "$(echo "$sbom_json" | jq -r '.type')" "sbom" "SBOM resource type" || return 1
  assert_eq "$(echo "$sbom_json" | jq -r '.relation')" "local" "SBOM resource relation" || return 1
  local access_type
  access_type="$(echo "$sbom_json" | jq -r '.access.type')"
  [[ "$access_type" =~ [Ll]ocal[Bb]lob ]] || \
    { echo "  expected LocalBlob access type, got: $access_type" >&2; return 1; }
  assert_eq "$(echo "$sbom_json" | jq -r '.access.mediaType')" \
    "application/vnd.cyclonedx+json" "SBOM media type" || return 1
  assert_eq "$(echo "$sbom_json" | jq -r '.version')" "$VERSION" "SBOM version" || return 1

  local label_signing
  label_signing="$(echo "$sbom_json" | jq -r \
    '.labels[] | select(.name=="ocm.software/artifact-references") | .signing')"
  assert_eq "$label_signing" "true" "artifact-references signing" || return 1

  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity "name=hello-world-sbom" --output "$tmp/sbom.cdx.json" >/dev/null
  local sbom_file="$tmp/sbom.cdx.json"
  [[ -f "$sbom_file" ]] || \
    { echo "  SBOM download did not write $sbom_file" >&2; return 1; }

  assert_eq "$(jq -r '.bomFormat' "$sbom_file")" "CycloneDX" "bomFormat" || return 1
  assert_eq "$(jq -r '.specVersion' "$sbom_file")" "1.6" "specVersion" || return 1
  assert_eq "$(jq -r '.metadata.component.name' "$sbom_file")" \
    "$ROOT_COMPONENT" "SBOM component name" || return 1
  assert_eq "$(jq -r '.metadata.component.version' "$sbom_file")" \
    "$VERSION" "SBOM component version" || return 1
  assert_eq "$(jq -r '.timestamp // "absent"' "$sbom_file")" "absent" "no timestamp" || return 1
  assert_eq "$(jq -r '.serialNumber // "absent"' "$sbom_file")" "absent" "no serialNumber" || return 1
}

test_sbom_describes_component_resources() {
  local tmp="$1"
  _build

  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity "name=hello-world-sbom" --output "$tmp/sbom.cdx.json" >/dev/null
  local sbom_file="$tmp/sbom.cdx.json"

  for arch in amd64 arm64; do
    local img_ref img_digest sbom_hash purl
    img_ref="$(echo "$cv_json" | jq -r --arg arch "$arch" \
      '.[0].component.resources[] | select(.name=="hello-world-image" and .extraIdentity.architecture==$arch) | .access.imageReference')"
    img_digest="${img_ref##*@sha256:}"
    sbom_hash="$(jq -r --arg ref "hello-world-image/$arch" \
      '.components[] | select(.["bom-ref"]==$ref) | .hashes[0].content' "$sbom_file")"
    assert_eq "$sbom_hash" "$img_digest" "SBOM hash matches image $arch digest" || return 1

    purl="$(jq -r --arg ref "hello-world-image/$arch" \
      '.components[] | select(.["bom-ref"]==$ref) | .purl' "$sbom_file")"
    [[ "$purl" == *"arch=$arch"* ]] || \
      { echo "  purl missing arch=$arch: $purl" >&2; return 1; }
  done

  while IFS=$'\t' read -r res_name rel_path; do
    local file_hash sbom_hash
    file_hash="$(sha256 "$ROOT/$rel_path")"
    sbom_hash="$(jq -r --arg ref "$res_name" \
      '.components[] | select(.["bom-ref"]==$ref) | .hashes[0].content' "$sbom_file")"
    assert_eq "$sbom_hash" "$file_hash" "SBOM hash matches $res_name source file" || return 1
  done <<'TABLE'
hello-world-manifests	components/hello-world/manifests.yaml
hello-world-localization	components/hello-world/localization.json
hello-world-config	components/hello-world/config.json
TABLE

  local dep_count comp_count
  dep_count="$(jq '.dependencies[0].dependsOn | length' "$sbom_file")"
  comp_count="$(jq '.components | length' "$sbom_file")"
  assert_eq "$dep_count" "$comp_count" "dependencies covers all components" || return 1
}

test_sbom_discovered_via_artifact_references() {
  local tmp="$1"
  _build

  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity "name=hello-world-sbom" --output "$tmp/direct.cdx.json" >/dev/null
  [[ -f "$tmp/direct.cdx.json" ]] || \
    { echo "  direct SBOM download did not write file" >&2; return 1; }

  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity "name=hello-world-manifests" --sbom --output "$tmp/s1" >/dev/null
  local s1_files=("$tmp/s1/"*.cdx.json)
  [[ ${#s1_files[@]} -eq 1 && -f "${s1_files[0]}" ]] || \
    { echo "  --sbom via manifests did not write exactly one .cdx.json" >&2; return 1; }

  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity "name=hello-world-image,architecture=arm64" --sbom --output "$tmp/s2" >/dev/null
  local s2_files=("$tmp/s2/"*.cdx.json)
  [[ ${#s2_files[@]} -eq 1 && -f "${s2_files[0]}" ]] || \
    { echo "  --sbom via arm64 image did not write exactly one .cdx.json" >&2; return 1; }

  cmp "$tmp/direct.cdx.json" "${s1_files[0]}" || \
    { echo "  --sbom output differs from direct download" >&2; return 1; }
}

test_sbom_regenerated_at_build_time() {
  local tmp="$1"
  export VERSION=9.9.9
  # SBOM_FILE is a shared on-disk path; must not run concurrently with test_sbom_generation_is_deterministic
  bash "$ROOT/scripts/build.sh" >/dev/null

  "$OCM" download resource "ctf::${tmp}/ctf//${ROOT_COMPONENT}:9.9.9" \
    --identity "name=hello-world-sbom" --output "$tmp/v999.cdx.json" >/dev/null
  local sbom_version
  sbom_version="$(jq -r '.metadata.component.version' "$tmp/v999.cdx.json")"
  assert_eq "$sbom_version" "9.9.9" "SBOM version propagates" || return 1
}

test_sbom_generation_is_deterministic() {
  local tmp="$1"
  _build

  # SBOM_FILE is a shared on-disk path; must not run concurrently with test_sbom_regenerated_at_build_time
  bash "$ROOT/scripts/sbom.sh" >/dev/null
  local h1
  h1="$(sha256 "$SBOM_FILE")"
  bash "$ROOT/scripts/sbom.sh" >/dev/null
  local h2
  h2="$(sha256 "$SBOM_FILE")"
  assert_eq "$h1" "$h2" "SBOM generation is deterministic" || return 1
}

test_sbom_link_is_signed() {
  local tmp="$1" out work
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null

  local filter='(.component.resources[] | select(.name=="hello-world-sbom") | .labels[] | select(.name=="ocm.software/artifact-references") | .value) = [{"identity":{"name":"deploy-bundle"}}]'
  work="$tmp/tampered"
  _tamper_descriptor "$CTF" "$VERSION" "$filter" "$work" || return 1

  out="$(CTF="$work" bash "$ROOT/scripts/verify.sh" </dev/null 2>&1)" \
    && { echo "  verify accepted tampered artifact-references label" >&2; return 1; }
  assert_contains "$out" "digest mismatch" || return 1
}

test_readme_documents_sboms() {
  local section
  section="$(awk '/^## Software Bills of Materials/{f=1;next} /^## /{f=0} f' "$ROOT/README.md")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## Software Bills of Materials' section" >&2; return 1; }

  local checks=(
    "https://ocm.software/docs/concepts/sboms/"
    "https://ocm.software/docs/tutorials/working-with-sboms/"
    "CycloneDX"
    "application/vnd.cyclonedx+json"
    "type: sbom"
    "ocm.software/artifact-references"
    "signing: true"
    "scripts/sbom.sh"
    "make build"
    "make sbom"
    "build/sbom/hello-world.cdx.json"
    "ocm get cv"
    "ocm download resource"
    "--sbom"
    "name=hello-world-sbom"
    "(#signing-and-verification)"
    "(#transfer-and-transport)"
  )

  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README SBOM section contains: $check" || return 1
  done

  assert_not_contains "$section" "ocm get resource " || return 1
}

test_product_references_application() {
  local tmp="$1" product_ctf cv_json ref_json
  product_ctf="$(_build_product "$tmp")"
  cv_json="$("$OCM" get cv "$(_product_ref "$product_ctf")" -o json)"

  # Must have exactly one componentReference
  assert_eq "$(echo "$cv_json" | jq '.[0].component.componentReferences | length')" \
    "1" "componentReferences count" || return 1

  ref_json="$(echo "$cv_json" | jq '.[0].component.componentReferences[0]')"
  assert_eq "$(echo "$ref_json" | jq -r '.name')" "application" "reference name" || return 1
  assert_eq "$(echo "$ref_json" | jq -r '.componentName')" "$ROOT_COMPONENT" "reference componentName" || return 1
  assert_eq "$(echo "$ref_json" | jq -r '.version')" "$VERSION" "reference version" || return 1

  # Digest must be set by ocm add cv
  local digest_norm digest_hash digest_value
  digest_norm="$(echo "$ref_json" | jq -r '.digest.normalisationAlgorithm')"
  digest_hash="$(echo "$ref_json" | jq -r '.digest.hashAlgorithm')"
  digest_value="$(echo "$ref_json" | jq -r '.digest.value')"
  assert_eq "$digest_norm" "jsonNormalisation/v4alpha1" "digest normalisationAlgorithm" || return 1
  assert_eq "$digest_hash" "SHA-256" "digest hashAlgorithm" || return 1
  [[ -n "$digest_value" && "$digest_value" != "null" ]] || \
    { echo "  reference digest.value is empty" >&2; return 1; }

  # Product CTF holds only the product component
  local repos
  repos="$(jq -r '[.artifacts[].repository] | sort | join(",")' "$product_ctf/artifact-index.json")"
  assert_eq "$repos" "component-descriptors/github.com/lioramilbaum/product" \
    "product CTF holds only the product" || return 1

  # App CTF is unchanged (still holds only the app component)
  local app_repos
  app_repos="$(jq -r '[.artifacts[].repository] | map(select(. == "component-descriptors/github.com/lioramilbaum/application")) | length' "$CTF/artifact-index.json")"
  [[ "$app_repos" -ge 1 ]] || { echo "  app CTF no longer holds application component" >&2; return 1; }
}

test_product_signature_covers_reference() {
  local tmp="$1" product_ctf work out
  product_ctf="$(_build_product "$tmp")"
  PRODUCT_CTF="$product_ctf" bash "$ROOT/scripts/product.sh" sign >/dev/null

  # Verify succeeds on clean product
  PRODUCT_CTF="$product_ctf" bash "$ROOT/scripts/product.sh" verify >/dev/null || \
    { echo "  verify failed on clean product" >&2; return 1; }

  # Tamper: change reference digest.value → verify must fail
  local filter1='(.component.componentReferences[0].digest.value) = "0000000000000000000000000000000000000000000000000000000000000000"'
  work="$tmp/tampered-digest"
  _tamper_descriptor "$product_ctf" "$VERSION" "$filter1" "$work" || return 1
  out="$(PRODUCT_CTF="$work" bash "$ROOT/scripts/product.sh" verify 2>&1)" \
    && { echo "  verify accepted tampered reference digest" >&2; return 1; }
  assert_contains "$out" "digest mismatch" || return 1

  # Tamper: change reference version → verify must fail
  local filter2='(.component.componentReferences[0].version) = "9.9.9"'
  work="$tmp/tampered-version"
  _tamper_descriptor "$product_ctf" "$VERSION" "$filter2" "$work" || return 1
  out="$(PRODUCT_CTF="$work" bash "$ROOT/scripts/product.sh" verify 2>&1)" \
    && { echo "  verify accepted tampered reference version" >&2; return 1; }
  assert_contains "$out" "digest mismatch" || return 1
}

test_recursive_transfer_enforces_reference_digest() {
  local tmp="$1" product_ctf out
  product_ctf="$(_build_product "$tmp")"
  bash "$ROOT/scripts/sign.sh" >/dev/null
  PRODUCT_CTF="$product_ctf" bash "$ROOT/scripts/product.sh" sign >/dev/null

  # Good path: recursive transfer succeeds
  "$OCM" transfer cv "$(_product_ref "$product_ctf")" "ctf::$tmp/target" \
    --recursive --config "$BUILD_DIR/resolvers.ocmconfig" >/dev/null || \
    { echo "  recursive transfer of clean product failed" >&2; return 1; }

  # Target must contain both components
  local target_repos
  target_repos="$(jq -r '[.artifacts[].repository] | sort | join(",")' "$tmp/target/artifact-index.json")"
  assert_contains "$target_repos" "github.com/lioramilbaum/application" "target has application" || return 1
  assert_contains "$target_repos" "github.com/lioramilbaum/product" "target has product" || return 1

  # Trust limitation: product verify still passes against tampered app
  local filter='(.component.provider) = "github.com/someoneelse"'
  _tamper_descriptor "$CTF" "$VERSION" "$filter" "$tmp/app-tampered" || return 1
  CTF="$tmp/app-tampered" BUILD_DIR="$tmp/resolvers-tampered" \
    bash "$ROOT/scripts/resolvers.sh" >/dev/null
  # product verify checks only product's own signature — passes even with tampered app
  PRODUCT_CTF="$product_ctf" VERIFY_CONFIG="$BUILD_DIR/verify.ocmconfig" \
    bash "$ROOT/scripts/product.sh" verify >/dev/null || \
    { echo "  verify correctly rejected tampered app (trust limitation may be fixed — update README)" >&2; return 1; }

  # Recursive transfer fails with digest mismatch when app is tampered
  out="$(PRODUCT_CTF="$product_ctf" \
    "$OCM" transfer cv "$(_product_ref "$product_ctf")" "ctf::$tmp/target2" \
    --recursive --config "$tmp/resolvers-tampered/resolvers.ocmconfig" 2>&1)" \
    && { echo "  recursive transfer accepted tampered app" >&2; return 1; }
  assert_contains "$out" "digest mismatch" || return 1
}

test_product_requires_resolvable_reference() {
  local tmp="$1" out

  # Missing app CTF → die with helpful message
  out="$(CTF="$tmp/missing-ctf" PRODUCT_CTF="$tmp/p1" bash "$ROOT/scripts/product.sh" build 2>&1)" \
    && { echo "  build succeeded with missing CTF" >&2; return 1; }
  assert_contains "$out" "Application CTF not found" || return 1

  # Wrong VERSION → ocm add cv fails (referenced app:9.9.9 does not exist)
  _build
  out="$(VERSION=9.9.9 PRODUCT_CTF="$tmp/p2" bash "$ROOT/scripts/product.sh" build 2>&1)" \
    && { echo "  build succeeded with unresolvable reference version" >&2; return 1; }
  # Should report some resolution error
  [[ -n "$out" ]] || { echo "  no error output for unresolvable reference" >&2; return 1; }
}

test_make_product_target() {
  local tmp="$1" dry_run help_out

  # Dry-run must invoke the three scripts
  dry_run="$(make -s --dry-run -C "$ROOT" product 2>/dev/null)"
  assert_contains "$dry_run" "scripts/build.sh" "dry-run includes build.sh" || return 1
  assert_contains "$dry_run" "scripts/sign.sh" "dry-run includes sign.sh" || return 1
  assert_contains "$dry_run" "scripts/product.sh" "dry-run includes product.sh" || return 1

  # make help must list product
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "product" "make help lists product" || return 1
}

test_readme_documents_component_references() {
  local readme="$ROOT/README.md"
  local section
  section="$(awk '/^## Component References/{f=1;next} /^## /{f=0} f' "$readme")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## Component References' section" >&2; return 1; }

  local checks=(
    "https://ocm.software/docs/how-to/model-products/"
    "componentReferences"
    "jsonNormalisation/v4alpha1"
    "make product"
    "build/product-ctf"
    "--recursive"
    "digest mismatch"
    "copy-or-fail"
    "ocm verify cv"
    "(#resolvers)"
    "(#canonical-component-repositories)"
    "(#signing-and-verification)"
    "(#transfer-and-transport)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: README yaml block (minus # lines) == constructor (minus # lines)
  local readme_yaml constructor_yaml
  readme_yaml="$(echo "$section" | awk '/^```yaml/{f=1;next} /^```/{f=0} f' | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/product/component-constructor.yaml")"
  [[ "$readme_yaml" = "$constructor_yaml" ]] || \
    { echo "  README yaml block differs from components/product/component-constructor.yaml" >&2; return 1; }

  # Resolvers section must no longer say "no componentReferences" and must link to this section
  local resolvers_section
  resolvers_section="$(awk '/^## Resolvers/{f=1;next} /^## /{f=0} f' "$readme")"
  assert_not_contains "$resolvers_section" "This repository has no \`componentReferences\`" || return 1
  assert_contains "$resolvers_section" "(#component-references)" || return 1
}

test_versions_lists_newest_first() {
  local tmp="$1"
  _build_versions "$tmp"
  local list
  list="$(VERSIONS_CTF="$tmp/versions-ctf" OCM="$VERSIONS_OCM" \
    bash "$ROOT/scripts/versions.sh" list | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$list" "1.1.0-rc.1 1.0.0 0.10.0 0.2.0 0.1.0" "release list order" || return 1

  # Each component version's release-notes resource must carry the matching version.
  local cv_json
  cv_json="$("$VERSIONS_OCM" get cv \
    "ctf::$tmp/versions-ctf//github.com/lioramilbaum/versions-demo" \
    --config "$tmp/versions-default.ocmconfig" -o json)" || return 1
  for v in 0.1.0 0.2.0 0.10.0 1.0.0 1.1.0-rc.1; do
    local rn_ver
    rn_ver="$(echo "$cv_json" \
      | jq -r --arg v "$v" \
        '.[] | select(.component.version==$v) | .component.resources[] | select(.name=="release-notes") | .version')"
    assert_eq "$rn_ver" "$v" "release-notes version for $v" || return 1
  done

  # Download the 0.2.0 release-notes and check its content.
  local dl_file="$tmp/release-notes-0.2.0.txt"
  "$VERSIONS_OCM" download resource \
    "ctf::$tmp/versions-ctf//github.com/lioramilbaum/versions-demo:0.2.0" \
    --identity "name=release-notes" \
    --config "$tmp/versions-default.ocmconfig" \
    --output "$dl_file" >/dev/null 2>&1 || return 1
  assert_eq "$(cat "$dl_file")" "github.com/lioramilbaum/versions-demo 0.2.0" \
    "release-notes content for 0.2.0" || return 1
}

test_versions_constraint_filters() {
  local tmp="$1"
  _build_versions "$tmp"
  local versions_env=(VERSIONS_CTF="$tmp/versions-ctf" OCM="$VERSIONS_OCM")

  local r
  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list '^0.1')"
  assert_eq "$r" "0.1.0" "^0.1 gives 0.1.0" || return 1

  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list '>= 0.2.0, < 1.0.0' | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$r" "0.10.0 0.2.0" ">= 0.2.0, < 1.0.0 gives 0.10.0 0.2.0" || return 1

  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list '1.x')"
  assert_eq "$r" "1.0.0" "1.x gives 1.0.0 (rc excluded)" || return 1

  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list '>= 1.1.0-0')"
  assert_eq "$r" "1.1.0-rc.1" ">= 1.1.0-0 gives 1.1.0-rc.1" || return 1

  # No match → die with helpful message.
  local err
  err="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list '>= 9.0.0' 2>&1)" \
    && { echo "  >= 9.0.0 should have failed" >&2; return 1; }
  assert_contains "$err" "no version of github.com/lioramilbaum/versions-demo" \
    ">= 9.0.0 error message" || return 1

  # Malformed constraint → ocm reports improper constraint.
  err="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" list 'not-a-constraint' 2>&1)" \
    && { echo "  not-a-constraint should have failed" >&2; return 1; }
  assert_contains "$err" "constraint" "malformed constraint error" || return 1
}

test_versions_latest_includes_prereleases_by_default() {
  local tmp="$1"
  _build_versions "$tmp"
  local versions_env=(VERSIONS_CTF="$tmp/versions-ctf" OCM="$VERSIONS_OCM")

  local r
  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" latest)"
  assert_eq "$r" "1.1.0-rc.1" "latest (default) returns pre-release" || return 1

  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" latest '>= 0.0.0')"
  assert_eq "$r" "1.0.0" "latest >= 0.0.0 returns stable" || return 1

  r="$(env "${versions_env[@]}" bash "$ROOT/scripts/versions.sh" latest '^0')"
  assert_eq "$r" "0.10.0" "latest ^0 returns 0.10.0" || return 1
}

test_versions_scheme_orders_build_numbers() {
  local tmp="$1"
  _build_versions "$tmp"

  local nightly_out
  nightly_out="$(env VERSIONS_CTF="$tmp/versions-ctf" NIGHTLY_CTF="$tmp/nightly-ctf" OCM="$VERSIONS_OCM" \
    bash "$ROOT/scripts/versions.sh" nightly)"
  assert_contains "$nightly_out" $'nightly\tall\tr100 r10 r9 r2' \
    "nightly all order" || return 1
  assert_contains "$nightly_out" $'nightly\tlatest\tr100' \
    "nightly latest" || return 1

  # Adding r9 without the scheme config must fail.
  local err
  printf '%s\n' 'type: generic.config.ocm.software/v1' 'configurations: []' > "$tmp/empty.ocmconfig"
  err="$(VERSION=r9 "$VERSIONS_OCM" add cv \
    --repository "ctf::$tmp/nightly-reject" \
    --constructor "$ROOT/components/versions/component-constructor.yaml" \
    --config "$tmp/empty.ocmconfig" 2>&1)" \
    && { echo "  r9 without scheme should have failed" >&2; return 1; }
  assert_contains "$err" "invalid version" "r9 without scheme error" || return 1

  # Adding 1.0.0 to the nightly CTF (which uses the build-number scheme) must also fail.
  err="$(VERSION=1.0.0 "$VERSIONS_OCM" add cv \
    --repository "ctf::$tmp/nightly-reject2" \
    --constructor "$ROOT/components/versions/component-constructor.yaml" \
    --config "$ROOT/components/versions/versioning.ocmconfig" 2>&1)" \
    && { echo "  1.0.0 with build-number scheme should have failed" >&2; return 1; }
  assert_contains "$err" "invalid version" "1.0.0 with build-number scheme error" || return 1
}

test_versions_without_scheme_misorders() {
  local tmp="$1"
  _build_versions "$tmp"

  local nightly_out
  nightly_out="$(env VERSIONS_CTF="$tmp/versions-ctf" NIGHTLY_CTF="$tmp/nightly-ctf" OCM="$VERSIONS_OCM" \
    bash "$ROOT/scripts/versions.sh" nightly)"
  # Without the scheme, OCM uses reverse-lexical order and returns r9 as latest.
  assert_contains "$nightly_out" $'nightly\tall (no scheme)\tr9 r2 r100 r10' \
    "no-scheme order is reverse lexical" || return 1
  assert_contains "$nightly_out" $'nightly\tlatest (no scheme)\tr9' \
    "no-scheme latest is r9" || return 1
}

test_versions_reference_requires_semver() {
  local tmp="$1"
  _build_versions "$tmp"

  # ocm download resource with a non-semver version string fails.
  local err
  err="$("$VERSIONS_OCM" download resource \
    "ctf::$tmp/nightly-ctf//github.com/lioramilbaum/versions-demo:r100" \
    --identity "name=release-notes" \
    --config "$ROOT/components/versions/versioning.ocmconfig" \
    --output "$tmp/rn-r100.txt" 2>&1)" \
    && { echo "  download resource :r100 should fail (limitation may be fixed — update README)" >&2; return 1; }
  assert_contains "$err" "invalid semantic version" \
    "download resource :r100 fails with invalid semantic version" || return 1

  # ocm transfer cv with a non-semver version does work.
  "$VERSIONS_OCM" transfer cv \
    "ctf::$tmp/nightly-ctf//github.com/lioramilbaum/versions-demo:r100" \
    "ctf::$tmp/transfer-target" \
    --config "$ROOT/components/versions/versioning.ocmconfig" >/dev/null 2>&1 || \
    { echo "  transfer cv :r100 should succeed" >&2; return 1; }
  assert_contains \
    "$(jq -r '[.artifacts[].tag] | join(" ")' "$tmp/transfer-target/artifact-index.json")" \
    "r100" "transfer target artifact-index has r100 tag" || return 1
}

test_versions_requires_ocm_019() {
  local tmp="$1"

  # Stub that mimics an older OCM binary with --semver-constraint instead of --constraint.
  local stub_bin="$tmp/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/ocm" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "get" && "${2:-}" == "cv" && "${3:-}" == "--help" ]]; then
  echo "      --semver-constraint string   filter by semver constraint"
  exit 0
fi
exit 0
STUB
  chmod +x "$stub_bin/ocm"

  local err
  err="$(OCM="$stub_bin/ocm" VERSIONS_CTF="$tmp/vc" NIGHTLY_CTF="$tmp/nc" \
    bash "$ROOT/scripts/versions.sh" list 2>&1)" \
    && { echo "  old-stub ocm should trigger the version gate" >&2; return 1; }
  assert_contains "$err" "requires OCM CLI >= 0.19.0" "version gate message" || return 1
}

test_versions_show_reports_selection() {
  local tmp="$1"
  _build_versions "$tmp"

  local out
  out="$(env VERSIONS_CTF="$tmp/versions-ctf" NIGHTLY_CTF="$tmp/nightly-ctf" OCM="$VERSIONS_OCM" \
    bash "$ROOT/scripts/versions.sh" show)"
  local line_count
  line_count="$(echo "$out" | wc -l | tr -d ' ')"
  assert_eq "$line_count" "10" "show output has 10 lines" || return 1
  assert_contains "$out" $'release\tlatest >= 0.0.0\t1.0.0' \
    "show: latest >= 0.0.0 line" || return 1
  assert_contains "$out" $'release\t1.x\t1.0.0' \
    "show: 1.x line" || return 1
}

test_make_versions_target() {
  local tmp="$1"

  local dry_run
  dry_run="$(make -s --dry-run -C "$ROOT" versions 2>/dev/null)"
  assert_contains "$dry_run" "scripts/versions.sh" "dry-run includes versions.sh" || return 1

  local help_out
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "versions" "make help lists versions" || return 1
}

test_readme_documents_version_selection() {
  local readme="$ROOT/README.md"
  local section
  section="$(awk '/^## Version selection/{f=1;next} /^## /{f=0} f' "$readme")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## Version selection' section" >&2; return 1; }

  local checks=(
    "https://ocm.software/docs/tutorials/configure-versioning/"
    "versioning.config.ocm.software/v1alpha1"
    "--constraint"
    "--semver-constraint"
    "--latest"
    "> 0.0.0-0"
    "1.1.0-rc.1"
    "make versions"
    "build/versions-ctf"
    "build/versions-nightly-ctf"
    "loose-semver"
    "invalid semantic version"
    "semverFilter"
    "versionConstraint"
    "(#resolvers)"
    "(#kubernetes-controller)"
    "(#component-references)"
    "(#component-identity)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: README yaml blocks (minus # lines) must match the two config files.
  # Block 1: constructor yaml
  local readme_yaml1 constructor_yaml
  readme_yaml1="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" \
    | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/versions/component-constructor.yaml")"
  [[ "$readme_yaml1" = "$constructor_yaml" ]] || \
    { echo "  README yaml block 1 differs from components/versions/component-constructor.yaml" >&2
      echo "  README: $readme_yaml1" >&2
      echo "  File:   $constructor_yaml" >&2
      return 1; }

  # Block 2: versioning config yaml
  local readme_yaml2 versioning_yaml
  readme_yaml2="$(awk '/^```yaml/{n++; f=(n==2); next} /^```/{f=0} f' <<<"$section" \
    | grep -v '^#')"
  versioning_yaml="$(grep -v '^#' "$ROOT/components/versions/versioning.ocmconfig")"
  [[ "$readme_yaml2" = "$versioning_yaml" ]] || \
    { echo "  README yaml block 2 differs from components/versions/versioning.ocmconfig" >&2
      echo "  README: $readme_yaml2" >&2
      echo "  File:   $versioning_yaml" >&2
      return 1; }

  # Component identity section must link to version-selection.
  local id_section
  id_section="$(awk '/^## Component identity/{f=1;next} /^## /{f=0} f' "$readme")"
  assert_contains "$id_section" "(#version-selection)" \
    "Component identity section links to version-selection" || return 1
}


test_helm_chart_resource_metadata() {
  local tmp="$1"
  _build_helm "$tmp"
  local res
  res="$("$OCM" get cv "$(_helm_ref "$tmp/helm-ctf")" -o json \
    | jq -c '.[0].component.resources[] | select(.name=="hello-world-chart")')"
  assert_eq "$(jq -r '.type' <<<"$res")" "helmChart" "resource type" || return 1
  assert_eq "$(jq -r '.relation' <<<"$res")" "local" "resource relation" || return 1
  local chart_version
  chart_version="$(awk '/^version:/{gsub(/"/,"",$2);print $2}' \
    "$ROOT/components/helm/chart/hello-world/Chart.yaml")"
  assert_eq "$(jq -r '.version' <<<"$res")" "$chart_version" "resource version" || return 1
  assert_eq "$(jq -r '.access.type' <<<"$res")" "LocalBlob/v1" "access type" || return 1
  assert_eq "$(jq -r '.access.mediaType' <<<"$res")" "application/vnd.oci.image.manifest.v1+json" "access mediaType" || return 1
  assert_eq "$(jq -r '.digest.normalisationAlgorithm' <<<"$res")" "genericBlobDigest/v1" "digest normalisation" || return 1
}

test_helm_chart_is_oci_artifact() {
  local tmp="$1"
  _build_helm "$tmp"
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_helm_ref "$tmp/helm-ctf")" < /dev/null >/dev/null || return 1
  HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1

  local layout="$tmp/helm-out/oci-layout"
  assert_eq "$(jq -r '.manifests[0].mediaType' "$layout/index.json")" \
    "application/vnd.oci.image.manifest.v1+json" "index manifest mediaType" || return 1
  assert_eq "$(jq -r '.manifests[0].annotations["org.opencontainers.image.ref.name"]' "$layout/index.json")" \
    "0.1.0" "index ref name" || return 1

  local manifest
  manifest="$layout/blobs/sha256/$(jq -r '.manifests[0].digest' "$layout/index.json" | sed 's/^sha256://')"
  assert_eq "$(jq -r '.config.mediaType' "$manifest")" \
    "application/vnd.cncf.helm.config.v1+json" "config mediaType" || return 1
  assert_eq "$(jq -r '.layers | length' "$manifest")" "1" "layer count" || return 1
  assert_eq "$(jq -r '.layers[0].mediaType' "$manifest")" \
    "application/vnd.cncf.helm.chart.content.v1.tar+gzip" "layer mediaType" || return 1
}

test_helm_transformer_extracts_chart() {
  local tmp="$1"
  _build_helm "$tmp"
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_helm_ref "$tmp/helm-ctf")" < /dev/null >/dev/null || return 1
  HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1

  local tgz="$tmp/helm-out/chart/hello-world-0.1.0.tgz"
  [[ -f "$tgz" ]] || { echo "  chart tgz not extracted" >&2; return 1; }

  local listing
  listing="$(tar -tzf "$tgz")"
  assert_contains "$listing" "hello-world/Chart.yaml" "tgz contains Chart.yaml" || return 1
  assert_contains "$listing" "hello-world/values.yaml" "tgz contains values.yaml" || return 1
  assert_contains "$listing" "hello-world/templates/deployment.yaml" "tgz contains deployment.yaml" || return 1

  local expected_app_version
  expected_app_version="$(awk '/^appVersion:/{gsub(/"/,"",$2);print $2}' \
    "$ROOT/components/helm/chart/hello-world/Chart.yaml")"

  # Helm re-serializes Chart.yaml when packaging, so compare the fields, not the bytes
  local extracted
  extracted="$(tar -xzOf "$tgz" hello-world/Chart.yaml)"
  assert_contains "$extracted" "name: hello-world" "Chart.yaml name" || return 1
  assert_contains "$extracted" "version: 0.1.0" "Chart.yaml version" || return 1
  assert_contains "$extracted" "$expected_app_version" "Chart.yaml appVersion" || return 1

  local manifest layer_digest
  manifest="$tmp/helm-out/oci-layout/blobs/sha256/$(jq -r '.manifests[0].digest' "$tmp/helm-out/oci-layout/index.json" | sed 's/^sha256://')"
  layer_digest="$(jq -r '.layers[] | select(.mediaType=="application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest' "$manifest")"
  assert_eq "sha256:$(sha256 "$tgz")" "$layer_digest" "layer digest is sha256 of chart tgz" || return 1

  # With --output ending in .tgz, OCM still writes a directory of that name
  "$OCM" download resource "$(_helm_ref "$tmp/helm-ctf")" \
    --identity name=hello-world-chart --transformer helm --output "$tmp/x.tgz" >/dev/null || return 1
  [[ -d "$tmp/x.tgz" ]] || { echo "  --output x.tgz should be a directory" >&2; return 1; }
}

test_helm_download_verifies_chart() {
  local tmp="$1"
  _build_helm "$tmp"
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_helm_ref "$tmp/helm-ctf")" < /dev/null >/dev/null || return 1

  HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" \
    bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1
  [[ -f "$tmp/helm-out/chart/hello-world-0.1.0.tgz" ]] || { echo "  verified download produced no chart" >&2; return 1; }

  local wrong_config
  wrong_config=$(_wrong_verify_config "$tmp")
  if VERIFY_CONFIG="$wrong_config" HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out2" \
    bash "$ROOT/scripts/helm.sh" download >/dev/null 2>&1; then
    echo "  download should fail with the wrong verification key" >&2
    return 1
  fi
  [[ ! -e "$tmp/helm-out2/chart" ]] || { echo "  chart must not be extracted after failed verification" >&2; return 1; }
}

test_helm_download_requires_signature() {
  local tmp="$1"
  _build_helm "$tmp"
  if HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" \
    bash "$ROOT/scripts/helm.sh" download >/dev/null 2>&1; then
    echo "  download should fail for an unsigned component" >&2
    return 1
  fi
  [[ ! -e "$tmp/helm-out/chart" ]] || { echo "  chart must not be extracted without a signature" >&2; return 1; }
}

test_helm_build_from_any_directory() {
  local tmp="$1"
  (cd / && HELM_DEMO_CTF="$tmp/helm-ctf-root" bash "$ROOT/scripts/helm.sh" build >/dev/null) || \
    { echo "  build from / failed" >&2; return 1; }
  [[ -d "$tmp/helm-ctf-root" ]] || { echo "  CTF not created from /" >&2; return 1; }
}

test_helm_chart_version_independent_of_component() {
  local tmp="$1"
  local chart_version
  chart_version="$(awk '/^version:/{gsub(/"/,"",$2);print $2}' \
    "$ROOT/components/helm/chart/hello-world/Chart.yaml")"

  VERSION=9.9.9 HELM_DEMO_CTF="$tmp/helm-ctf" bash "$ROOT/scripts/helm.sh" build >/dev/null || return 1

  local cv_json
  cv_json="$("$OCM" get cv "ctf::$tmp/helm-ctf//github.com/lioramilbaum/helm-demo:9.9.9" -o json)" || return 1
  assert_eq "$(jq -r '.[0].component.version' <<<"$cv_json")" "9.9.9" "component version" || return 1
  assert_eq "$(jq -r '.[0].component.resources[] | select(.name=="hello-world-chart") | .version' <<<"$cv_json")" \
    "$chart_version" "chart resource version" || return 1

  VERSION=9.9.9 HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1
  [[ -f "$tmp/helm-out/chart/hello-world-$chart_version.tgz" ]] || { echo "  chart tgz should be named after the chart version" >&2; return 1; }
}

test_helm_chart_layer_is_reproducible() {
  local tmp="$1" side
  for side in a b; do
    HELM_DEMO_CTF="$tmp/ctf-$side" bash "$ROOT/scripts/helm.sh" build >/dev/null || return 1
    HELM_DEMO_CTF="$tmp/ctf-$side" HELM_DEMO_OUT="$tmp/out-$side" SKIP_VERIFY=1 \
      bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1
  done
  # chart layer reproducibility is an implementation detail; revisit on OCM upgrades
  assert_eq "$(sha256 "$tmp/out-a/chart/hello-world-0.1.0.tgz")" \
    "$(sha256 "$tmp/out-b/chart/hello-world-0.1.0.tgz")" "chart tgz identical across builds" || return 1

  local manifest created
  manifest="$tmp/out-a/oci-layout/blobs/sha256/$(jq -r '.manifests[0].digest' "$tmp/out-a/oci-layout/index.json" | sed 's/^sha256://')"
  created="$(jq -r '.annotations["org.opencontainers.image.created"] // ""' "$manifest")"
  [[ -n "$created" ]] || { echo "  manifest missing org.opencontainers.image.created" >&2; return 1; }
}

test_helm_input_rejects_invalid_chart() {
  local tmp="$1"
  local chart="$tmp/no-chart"
  mkdir -p "$chart"
  echo 'replicaCount: 1' > "$chart/values.yaml"

  local constructor="$tmp/bad-constructor.yaml"
  cat > "$constructor" <<YAML
name: github.com/lioramilbaum/helm-demo
version: 0.1.0
provider:
  name: github.com/lioramilbaum
resources:
  - name: hello-world-chart
    type: helmChart
    version: 0.1.0
    input:
      type: helm/v1
      path: ${chart}
YAML

  local out
  if out="$("$OCM" add cv --repository "ctf::$tmp/bad-ctf" --constructor "$constructor" 2>&1)"; then
    echo "  add cv should reject a directory without Chart.yaml" >&2
    return 1
  fi
  assert_contains "$out" "Chart.yaml" "error names Chart.yaml"
}

test_helm_access_resolved_at_build_time() {
  local tmp="$1"
  local constructor="$tmp/access-constructor.yaml"
  cat > "$constructor" <<YAML
name: github.com/lioramilbaum/helm-demo
version: 0.1.0
provider:
  name: github.com/lioramilbaum
resources:
  - name: hello-world-chart
    type: helmChart
    version: 0.1.0
    access:
      type: Helm/v1
      helmRepository: http://127.0.0.1:1/charts
      helmChart: hello-world:0.1.0
YAML

  local out
  if out="$("$OCM" add cv --repository "ctf::$tmp/access-ctf" --constructor "$constructor" 2>&1)"; then
    echo "  add cv should fail when the Helm repository is unreachable" >&2
    return 1
  fi
  # error message may vary across OCM versions
  assert_contains "$out" "repository index"
}

test_helm_transfer_keeps_chart_local() {
  local tmp="$1"
  _build_helm "$tmp"
  "$OCM" transfer cv "$(_helm_ref "$tmp/helm-ctf")" "ctf::$tmp/helm-transferred" >/dev/null || return 1

  local src_res tgt_res
  src_res="$("$OCM" get cv "$(_helm_ref "$tmp/helm-ctf")" -o json \
    | jq -c '.[0].component.resources[] | select(.name=="hello-world-chart")')"
  tgt_res="$("$OCM" get cv "ctf::$tmp/helm-transferred//github.com/lioramilbaum/helm-demo:${VERSION}" -o json \
    | jq -c '.[0].component.resources[] | select(.name=="hello-world-chart")')"
  assert_eq "$(jq -r '.access.type' <<<"$tgt_res")" "LocalBlob/v1" "transferred access type" || return 1
  assert_eq "$(jq -r '.access.localReference' <<<"$tgt_res")" \
    "$(jq -r '.access.localReference' <<<"$src_res")" "localReference unchanged by transfer" || return 1

  "$OCM" download resource "$(_helm_ref "$tmp/helm-ctf")" \
    --identity name=hello-world-chart --transformer helm --output "$tmp/src-chart" >/dev/null || return 1
  "$OCM" download resource "ctf::$tmp/helm-transferred//github.com/lioramilbaum/helm-demo:${VERSION}" \
    --identity name=hello-world-chart --transformer helm --output "$tmp/tgt-chart" >/dev/null || return 1
  assert_eq "$(sha256 "$tmp/src-chart/hello-world-0.1.0.tgz")" \
    "$(sha256 "$tmp/tgt-chart/hello-world-0.1.0.tgz")" "chart tgz identical after transfer"
}

test_helm_values_from_component() {
  local tmp="$1"
  _build
  bash "$ROOT/scripts/sign.sh" >/dev/null || return 1

  local amd64_file arm64_file
  amd64_file="$(TARGET_ARCH=amd64 HELM_DEMO_OUT="$tmp/helm-amd64" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" values)" || return 1
  arm64_file="$(TARGET_ARCH=arm64 HELM_DEMO_OUT="$tmp/helm-arm64" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" values)" || return 1

  local amd64_values
  amd64_values="$(cat "$amd64_file")"
  assert_contains "$amd64_values" "repository: docker.io/library/nginx" "values repository" || return 1
  assert_contains "$amd64_values" "tag: 1.31-alpine" "values tag" || return 1
  assert_contains "$amd64_values" "digest: sha256:" "values digest" || return 1

  local amd64_digest arm64_digest
  amd64_digest="$(sed -n 's/^  digest: //p' "$amd64_file")"
  arm64_digest="$(sed -n 's/^  digest: //p' "$arm64_file")"
  [[ -n "$amd64_digest" && "$amd64_digest" != "$arm64_digest" ]] || \
    { echo "  amd64 and arm64 values should carry different digests" >&2; return 1; }
}

test_helm_values_requires_application_ctf() {
  local tmp="$1" out
  if out="$(CTF="$tmp/missing" HELM_DEMO_OUT="$tmp/helm-out" bash "$ROOT/scripts/helm.sh" values 2>&1)"; then
    echo "  values should fail without the application CTF" >&2
    return 1
  fi
  assert_contains "$out" "Application CTF not found"
}

test_helm_show_reports_chart() {
  local tmp="$1"
  _build_helm "$tmp"
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_helm_ref "$tmp/helm-ctf")" < /dev/null >/dev/null || return 1
  HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/helm.sh" download >/dev/null || return 1

  local out
  out="$(HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/helm-out" bash "$ROOT/scripts/helm.sh" show)" || return 1
  assert_contains "$out" $'resource\thello-world-chart\thelmChart\t0.1.0' "show resource line" || return 1
  assert_contains "$out" $'access\tLocalBlob/v1\tapplication/vnd.oci.image.manifest.v1+json' "show access line" || return 1
  assert_contains "$out" $'config\tapplication/vnd.cncf.helm.config.v1+json' "show config line" || return 1
  assert_contains "$out" $'layer\tapplication/vnd.cncf.helm.chart.content.v1.tar+gzip\tsha256:' "show layer line" || return 1

  local err
  if err="$(HELM_DEMO_CTF="$tmp/helm-ctf" HELM_DEMO_OUT="$tmp/none" bash "$ROOT/scripts/helm.sh" show 2>&1)"; then
    echo "  show should fail before download" >&2
    return 1
  fi
  assert_contains "$err" "run scripts/helm.sh download first" "show before download"
}

test_make_helm_target() {
  local tmp="$1"

  local dry_run
  dry_run="$(make -s --dry-run -C "$ROOT" helm 2>/dev/null)"
  assert_contains "$dry_run" "scripts/helm.sh" "dry-run includes helm.sh" || return 1

  local help_out
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "helm" "make help lists helm"
}

test_readme_documents_helm_charts() {
  local readme="$ROOT/README.md"
  local section
  section="$(awk '/^## Helm charts/{f=1;next} /^## /{f=0} f' "$readme")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## Helm charts' section" >&2; return 1; }

  local checks=(
    "helmChart"
    "helm/v1"
    "Helm/v1"
    "helmRepository"
    "--transformer helm"
    "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    "application/vnd.cncf.helm.config.v1+json"
    "org.opencontainers.image.created"
    "#3901"
    "error downloading repository index"
    "make helm"
    "build/helm-ctf"
    "values.ocm.yaml"
    "(#plugin-system)"
    "(#signing-and-verification)"
    "(#transfer-and-transport)"
    "(#version-selection)"
    "(#kubernetes-deployer)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first README yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" \
    | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/helm/component-constructor.yaml")"
  [[ "$readme_yaml" = "$constructor_yaml" ]] || \
    { echo "  README yaml block differs from components/helm/component-constructor.yaml" >&2
      echo "  README: $readme_yaml" >&2
      echo "  File:   $constructor_yaml" >&2
      return 1; }

  local res_section
  res_section="$(awk '/^## Resource repositories/{f=1;next} /^## /{f=0} f' "$readme")"
  assert_contains "$res_section" "(#helm-charts)" "Resource repositories links to helm charts"
}

_wget_env() {
  local tmp="$1"
  export WGET_DEMO_CTF="$tmp/wget-ctf" WGET_DEMO_OUT="$tmp/wget" OCM="$WGET_OCM"
}

_build_wget() {
  local tmp="$1"
  _wget_env "$tmp"
  bash "$ROOT/scripts/wget.sh" build
}

_wget_ref() {
  local ctf="$1"
  echo "ctf::${ctf}//github.com/lioramilbaum/wget-demo:${VERSION}"
}

test_wget_resources_metadata() {
  local tmp="$1"
  _build_wget "$tmp" >/dev/null 2>&1 || return 1

  local json rn hp
  json="$("$OCM" get cv "$(_wget_ref "$tmp/wget-ctf")" -o json)" || return 1
  rn="$(jq -c '.[0].component.resources[] | select(.name=="release-notes")' <<<"$json")"
  hp="$(jq -c '.[0].component.resources[] | select(.name=="hello-world-page")' <<<"$json")"

  assert_eq "$(jq -r '.access.type' <<<"$rn")" "LocalBlob/v1" "release-notes access" || return 1
  assert_contains "$(jq -r '.access.mediaType' <<<"$rn")" "text/plain" "release-notes mediaType" || return 1
  assert_eq "$(jq -r '.digest.hashAlgorithm' <<<"$rn")" "SHA-256" "release-notes hashAlgorithm" || return 1
  assert_eq "$(jq -r '.digest.value' <<<"$rn")" "$(sha256 "$ROOT/components/wget/upstream/release-notes.txt")" "release-notes digest" || return 1

  assert_eq "$(jq -r '.access.type' <<<"$hp")" "Wget/v1" "hello-world-page access" || return 1
  assert_eq "$(jq -r '.access.url' <<<"$hp")" "http://127.0.0.1:18431/index.html" "hello-world-page url" || return 1
  assert_eq "$(jq -r '.digest.hashAlgorithm' <<<"$hp")" "SHA-256" "hello-world-page hashAlgorithm" || return 1
  assert_eq "$(jq -r '.digest.value' <<<"$hp")" "$(sha256 "$ROOT/components/wget/upstream/index.html")" "hello-world-page digest" || return 1
}

test_wget_pinned_digest_matches_upstream_file() {
  local pinned
  pinned="$(awk '/name: hello-world-page/{f=1} f && /value:/{gsub(/"/,"",$2); print $2; exit}' \
    "$ROOT/components/wget/component-constructor.yaml")"
  assert_eq "$pinned" "$(sha256 "$ROOT/components/wget/upstream/index.html")" "pinned digest equals upstream file"
}

test_wget_pinned_digest_rejects_mismatch() {
  local tmp="$1" bad fake_digest out
  bad="$tmp/constructor-bad.yaml"
  fake_digest="$(printf 'a%.0s' {1..64})"
  sed "s/value: \"[0-9a-f]*\"/value: \"$fake_digest\"/" "$ROOT/components/wget/component-constructor.yaml" > "$bad"

  _wget_env "$tmp"
  if out="$(WGET_DEMO_CONSTRUCTOR="$bad" bash "$ROOT/scripts/wget.sh" build 2>&1)"; then
    echo "  build with a wrong pinned digest should fail" >&2
    return 1
  fi
  assert_contains "$out" "digest mismatch" || assert_contains "$out" "provided digest" || return 1
  if "$OCM" get cv "$(_wget_ref "$tmp/wget-ctf")" -o json >/dev/null 2>&1; then
    echo "  component version should not exist after a rejected build" >&2
    return 1
  fi
}

test_wget_input_embeds_bytes_at_build_time() {
  local tmp="$1" r
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" tamper >/dev/null || return 1

  "$OCM" download resource --identity name=release-notes --output "$tmp/rn" \
    "$(_wget_ref "$tmp/wget-ctf")" >/dev/null 2>&1
  r=$?
  assert_eq "$r" "0" "download release-notes without a server" || return 1
  cmp -s "$tmp/rn" "$ROOT/components/wget/upstream/release-notes.txt" || {
    echo "  release-notes bytes differ from the upstream file" >&2
    return 1
  }
}

test_wget_access_needs_server_at_consume_time() {
  local tmp="$1"
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  if "$OCM" download resource --identity name=hello-world-page --output "$tmp/page" \
    "$(_wget_ref "$tmp/wget-ctf")" >/dev/null 2>&1; then
    echo "  download of the Wget/v1 access should fail without a server" >&2
    return 1
  fi
}

test_wget_download_rejects_changed_upstream() {
  local tmp="$1" out json f want got
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" tamper >/dev/null || return 1

  if out="$(bash "$ROOT/scripts/wget.sh" download 2>&1)"; then
    echo "  download of a changed upstream should fail" >&2
    return 1
  fi
  assert_contains "$out" "hello-world-page" || return 1
  assert_contains "$out" "mismatch" || return 1
  [[ ! -d "$tmp/wget/download" ]] || { echo "  download dir should not exist" >&2; return 1; }
  if compgen -G "$tmp/wget/.download.*" >/dev/null; then
    echo "  temporary download dirs were left behind" >&2
    return 1
  fi

  bash "$ROOT/scripts/wget.sh" restore || return 1
  SKIP_VERIFY=1 bash "$ROOT/scripts/wget.sh" download >/dev/null 2>&1 || return 1
  json="$("$OCM" get cv "$(_wget_ref "$tmp/wget-ctf")" -o json)" || return 1
  for f in release-notes hello-world-page; do
    want="$(jq -r --arg r "$f" '.[0].component.resources[] | select(.name==$r) | .digest.value' <<<"$json")"
    got="$(sha256 "$tmp/wget/download/$f")"
    assert_eq "$got" "$want" "$f digest after restore" || return 1
  done
}

test_wget_download_requires_signature() {
  local tmp="$1"
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  if bash "$ROOT/scripts/wget.sh" download >/dev/null 2>&1; then
    echo "  download of an unsigned component should fail" >&2
    return 1
  fi
  [[ ! -d "$tmp/wget/download" ]] || { echo "  download dir should not exist" >&2; return 1; }
}

test_wget_checksum_require_rejects_unadvertised() {
  local tmp="$1" out
  _wget_env "$tmp"
  if out="$(WGET_DEMO_DIGEST=none WGET_DEMO_CHECKSUM_MODE=Require bash "$ROOT/scripts/wget.sh" build 2>&1)"; then
    echo "  Require should reject a response without a checksum" >&2
    return 1
  fi
  assert_contains "$out" "no advertised checksum" || assert_contains "$out" "onMissing" || return 1
  WGET_DEMO_DIGEST=sha-256 WGET_DEMO_CHECKSUM_MODE=Require bash "$ROOT/scripts/wget.sh" build >/dev/null 2>&1 || {
    echo "  Require should accept an advertised sha-256 checksum" >&2
    return 1
  }
}

test_wget_checksum_matrix() {
  local tmp="$1" out line
  _wget_env "$tmp"
  out="$(bash "$ROOT/scripts/wget.sh" checksum 2>/dev/null)" || return 1
  assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "7" "matrix has 7 rows" || return 1

  local rows=(
    $'none\tSkip\tok\tSHA-256'
    $'none\tPrefer\tok\tSHA-256'
    $'none\tRequire\tfail\tmissing-checksum'
    $'sha-256\tRequire\tok\tSHA-256'
    $'wrong\tPrefer\tfail\tmismatch'
    $'wrong\tSkip\tok\tSHA-256'
    $'sha-512\tPrefer\tfail\talgorithm-mismatch'
  )
  for line in "${rows[@]}"; do
    assert_contains "$out" "$line" "matrix row" || return 1
  done
}

test_wget_rejects_invalid_checksum_mode() {
  local tmp="$1" out
  _wget_env "$tmp"
  if out="$(WGET_DEMO_CHECKSUM_MODE=Requre bash "$ROOT/scripts/wget.sh" build 2>&1)"; then
    echo "  an invalid checksum mode should fail" >&2
    return 1
  fi
  assert_contains "$out" "must be Require, Prefer or Skip"
}

test_wget_credentials_resolved_by_url_identity() {
  local tmp="$1" port=18432 pid cfg creds_cfg constructor out
  mkdir -p "$tmp/auth-root"
  printf 'hello\n' > "$tmp/auth-root/secret.txt"
  printf 'none\n' > "$tmp/digest-mode"
  printf 'demo:s3cret\n' > "$tmp/auth"
  python3 -I "$ROOT/scripts/upstream-server.py" --root "$tmp/auth-root" --port "$port" \
    --digest-file "$tmp/digest-mode" --auth-file "$tmp/auth" >"$tmp/auth-server.log" 2>&1 &
  pid=$!
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true" EXIT
  for _ in $(seq 1 20); do
    curl -fsS --max-time 1 "http://127.0.0.1:$port/-/ready" >/dev/null 2>&1 && break
    sleep 0.25
  done

  cfg="$tmp/empty.ocmconfig"
  printf 'type: generic.config.ocm.software/v1\nconfigurations: []\n' > "$cfg"
  constructor="$tmp/auth-constructor.yaml"
  cat > "$constructor" <<EOF
name: github.com/lioramilbaum/wget-auth-demo
version: 0.1.0
provider:
  name: github.com/lioramilbaum
resources:
  - name: secret
    type: blob
    version: 0.1.0
    input:
      type: Wget/v1
      url: http://127.0.0.1:$port/secret.txt
      mediaType: text/plain
EOF

  if out="$("$WGET_OCM" add cv --repository "ctf::$tmp/auth-ctf" --constructor "$constructor" --config "$cfg" 2>&1)"; then
    echo "  unauthenticated fetch should fail" >&2
    return 1
  fi
  assert_contains "$out" "401" || return 1

  creds_cfg="$tmp/creds.ocmconfig"
  cat > "$creds_cfg" <<'EOF'
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: Wget
          hostname: 127.0.0.1
          port: "18432"
          scheme: http
        credentials:
          - type: WgetCredentials/v1
            username: demo
            password: s3cret
EOF
  "$WGET_OCM" add cv --repository "ctf::$tmp/auth-ctf-ok" --constructor "$constructor" --config "$creds_cfg" >/dev/null 2>&1 || {
    echo "  authenticated fetch should succeed" >&2
    return 1
  }
}

test_wget_transfer_reference_vs_copy() {
  local tmp="$1" out
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" sign >/dev/null 2>&1 || return 1

  out="$(bash "$ROOT/scripts/wget.sh" transfer 2>&1)" || return 1
  assert_contains "$out" $'reference\thello-world-page\texternal\tWget/v1' || return 1
  assert_contains "$out" $'copy\thello-world-page\texternal\tLocalBlob/v1' || return 1
  "$OCM" verify cv --config "$tmp/verify.ocmconfig" --signature default \
    "ctf::$tmp/wget/transfer-copy-ctf//github.com/lioramilbaum/wget-demo:$VERSION" </dev/null >/dev/null 2>&1 || {
    echo "  signature on the transferred copy should verify" >&2
    return 1
  }
}

test_wget_transfer_copy_enforces_digest() {
  local tmp="$1" out
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/wget.sh" tamper >/dev/null || return 1

  if out="$(bash "$ROOT/scripts/wget.sh" transfer 2>&1)"; then
    echo "  transfer of a changed upstream should fail" >&2
    return 1
  fi
  assert_contains "$out" "digest mismatch"
}

test_wget_requires_ocm_019() {
  local tmp="$1" out
  cat > "$tmp/fake-ocm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then
  printf 'OCM CLI (Open Component Model v2)\n  Version:  0.17.0\n'
  exit 0
fi
exit 1
EOF
  chmod 0755 "$tmp/fake-ocm"
  WGET_OCM="$tmp/fake-ocm"
  _wget_env "$tmp"

  if out="$(bash "$ROOT/scripts/wget.sh" show 2>&1)"; then
    echo "  wget.sh should refuse OCM 0.17.0" >&2
    return 1
  fi
  assert_contains "$out" "requires OCM CLI >= 0.19.0"
}

test_wget_server_port_in_use() {
  local tmp="$1" port="${WGET_DEMO_PORT:-18431}" pid out
  _wget_env "$tmp"
  # SO_REUSEADDR: a port left in TIME_WAIT by earlier tests must not stop the listener from binding.
  python3 -I -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $port)); s.listen(); time.sleep(60)" &
  pid=$!
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true" EXIT
  # Poll with a TCP connect (not HTTP) since the holder is a raw socket, not an HTTP server.
  local i=0
  while ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    i=$((i+1)); [[ $i -lt 10 ]] || { echo "port holder never bound" >&2; return 1; }
    sleep 0.3
  done
  exec 3>&- 2>/dev/null || true

  if out="$(bash "$ROOT/scripts/wget.sh" build 2>&1)"; then
    echo "  build should fail when the port is in use" >&2
    return 1
  fi
  assert_contains "$out" "upstream server failed to start"
}

test_wget_show_reports_resources() {
  local tmp="$1" out
  _build_wget "$tmp" >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/wget.sh" show 2>&1)" || return 1
  assert_contains "$out" $'release-notes\tlocal\tLocalBlob/v1\tSHA-256' || return 1
  assert_contains "$out" $'hello-world-page\texternal\tWget/v1\tSHA-256'
}

test_make_wget_target() {
  local tmp="$1"

  local dry_run
  dry_run="$(make -s --dry-run -C "$ROOT" wget 2>/dev/null)"
  assert_contains "$dry_run" "scripts/wget.sh" "dry-run includes wget.sh" || return 1

  local help_out
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "wget" "make help lists wget"
}

test_readme_documents_http_resources() {
  local readme="$ROOT/README.md"
  local section
  section="$(awk '/^## HTTP resources/{f=1;next} /^## /{f=0} f' "$readme")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## HTTP resources' section" >&2; return 1; }

  local checks=(
    "Wget/v1"
    "HTTP/v1"
    "checksum.http.config.ocm.software/v1alpha1"
    "Require"
    "Prefer"
    "Skip"
    "Content-Digest"
    "WgetCredentials/v1"
    "localblob.uploader.transfer.config.ocm.software/v1alpha1"
    "digest mismatch"
    "only SHA-256 is supported"
    "#3889"
    "make wget"
    "build/wget-ctf"
    "(#resource-repositories)"
    "(#signing-and-verification)"
    "(#credential-system)"
    "(#transfer-and-transport)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first README yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" \
    | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/wget/component-constructor.yaml")"
  [[ "$readme_yaml" = "$constructor_yaml" ]] || \
    { echo "  README yaml block differs from components/wget/component-constructor.yaml" >&2
      echo "  README: $readme_yaml" >&2
      echo "  File:   $constructor_yaml" >&2
      return 1; }

  local res_section
  res_section="$(awk '/^## Resource repositories/{f=1;next} /^## /{f=0} f' "$readme")"
  assert_contains "$res_section" "(#http-resources)" "Resource repositories links to http resources"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

run_test "build produces application tree" test_build_produces_application_tree
run_test "ocm does not block on open stdin" test_ocm_does_not_block_on_open_stdin
run_test "image resource is pinned by digest" test_image_resource_is_pinned_by_digest
run_test "manifests resource metadata" test_manifests_resource_metadata
run_test "localization resource metadata" test_localization_resource_metadata
run_test "sign and verify succeed" test_sign_and_verify_succeed
run_test "verify rejects wrong key" test_verify_rejects_wrong_key
run_test "version is propagated" test_version_is_propagated
run_test "manifests renders pinned image" test_manifests_renders_pinned_image
run_test "manifests is idempotent" test_manifests_is_idempotent
run_test "cv_ref honours OCM_COMPONENT_REPO" test_cv_ref_honours_component_repo
run_test "manifests reads from OCM_COMPONENT_REPO" test_manifests_reads_from_component_repo
run_test "manifests localizes transferred image" test_manifests_localizes_transferred_image
run_test "manifests rejects mismatched image digest" test_manifests_rejects_mismatched_image_digest
run_test "manifests rejects missing image digest" test_manifests_rejects_missing_image_digest
run_test "manifests localizes by rule not placeholder" test_manifests_localizes_by_rule_not_placeholder
run_test "manifests rejects untargeted localization" test_manifests_rejects_untargeted_localization
run_test "manifests rejects wrong container" test_manifests_rejects_wrong_container
run_test "manifests rejects tampered localization" test_manifests_rejects_tampered_localization
run_test "config resource metadata" test_config_resource_metadata
run_test "manifests applies config values" test_manifests_applies_config_values
run_test "manifests rejects tampered config" test_manifests_rejects_tampered_config
run_test "manifests rejects untargeted config" test_manifests_rejects_untargeted_config
run_test "manifests rejects invalid config" test_manifests_rejects_invalid_config
run_test "deploy verifies before deploying" test_deploy_verifies_before_deploying
run_test "deploy applies rendered manifests" test_deploy_applies_rendered_manifests
run_test "deploy fails when rollout fails" test_deploy_fails_when_rollout_fails
run_test "deploy bundle metadata" test_deploy_bundle_metadata
run_test "deploy bundle download identical" test_deploy_bundle_download_identical
run_test "source references git commit" test_source_references_git_commit
run_test "build rejects invalid source commit" test_build_rejects_invalid_source_commit
run_test "verify ignores other signatures" test_verify_ignores_other_signatures
run_test "sigstore config generation" test_sigstore_config_generation
run_test "sigstore sign requires oidc token" test_sigstore_sign_requires_oidc_token
run_test "sign rejects unknown signing method" test_sign_rejects_unknown_signing_method
run_test "bundle is self-contained" test_bundle_is_self_contained
run_test "cluster.sh creates missing cluster" test_cluster_sh_creates_missing_cluster
run_test "cluster.sh reuses existing cluster" test_cluster_sh_reuses_existing_cluster
run_test "cluster.sh down deletes cluster" test_cluster_sh_down_deletes_cluster
run_test "cluster.sh configures local registry mirror" test_cluster_sh_configures_local_registry_mirror
run_test "make e2e-run skips build and sign" test_make_e2e_run_skips_build_sign
run_test "devcontainer config is valid" test_devcontainer_config_is_valid
run_test "devcontainer pins tools" test_devcontainer_pins_tools
run_test "renovate updates OCM SHA256 ARGs" test_renovate_updates_ocm_sha256
run_test "e2e workflow isolates deploy" test_e2e_workflow_isolates_deploy
run_test "publish passes registry credentials via ocm config" test_publish_passes_registry_credentials_via_ocm_config
run_test "publish does not write registry secret" test_publish_does_not_write_registry_secret
run_test "publish without registry credentials uses discovery" test_publish_without_registry_credentials_uses_discovery
run_test "publish rejects partial registry credentials" test_publish_rejects_partial_registry_credentials
run_test "registry identity derived from OCM_REPO" test_registry_identity_derived_from_ocm_repo
run_test "registry ocmconfig is valid for ocm" test_registry_ocmconfig_is_valid_for_ocm
run_test "release publishes with OCM credentials" test_release_publishes_with_ocm_credentials
run_test "resolvers config is valid for ocm" test_resolvers_config_is_valid_for_ocm
run_test "resolvers resolve component reference" test_resolvers_resolve_component_reference
run_test "resolvers honour version constraint and order" test_resolvers_honour_version_constraint_and_order
run_test "resource access types" test_resource_access_types
run_test "readme documents resource access types" test_readme_documents_resource_access_types
run_test "publish copies resources as OCI artifacts" test_publish_copies_resources_as_oci_artifacts
run_test "transfer without copy-resources keeps external reference" test_transfer_without_copy_resources_keeps_external_reference
run_test "transfer copy-resources inlines image as local blob" test_transfer_copy_resources_inlines_image_as_local_blob
run_test "transfer copy-resources uploads OCI artifact" test_transfer_copy_resources_uploads_oci_artifact
run_test "transfer plan lists expected operations" test_transfer_plan_lists_expected_operations
run_test "transfer plan replay preserves signature" test_transfer_plan_replay_preserves_signature
run_test "publish replays transfer spec" test_publish_replays_transfer_spec
run_test "transfer config routes images per architecture" test_transfer_config_routes_images_per_architecture
run_test "readme documents transfer and transport" test_readme_documents_transfer_and_transport
run_test "ctf layout is canonical" test_ctf_layout_is_canonical
run_test "ctf archive is portable and signed" test_ctf_archive_is_portable_and_signed
run_test "readme documents canonical component repositories" test_readme_documents_canonical_component_repositories
run_test "readme documents kubernetes controller" test_readme_documents_kubernetes_controller
run_test "readme documents kubernetes deployer" test_readme_documents_kubernetes_deployer
run_test "builtin plugins serve component types" test_builtin_plugins_serve_component_types
run_test "readme documents plugin system" test_readme_documents_plugin_system
run_test "signature covers normalized descriptor" test_signature_covers_normalized_descriptor
run_test "readme documents signing and verification" test_readme_documents_signing_and_verification
run_test "component identity selects artifacts" test_component_identity_selects_artifacts
run_test "component identity rules enforced" test_component_identity_rules_enforced
run_test "readme documents component identity" test_readme_documents_component_identity
run_test "manifests selects target architecture variant" test_manifests_selects_target_arch_variant
run_test "discovery selects image variants" test_discovery_selects_image_variants
run_test "readme documents kubernetes component discovery" test_readme_documents_kubernetes_component_discovery
run_test "ownership records owner" test_ownership_records_owner
run_test "ownership record is deterministic" test_ownership_record_is_deterministic
run_test "ownership survives transfer" test_ownership_survives_transfer
run_test "ownership trace reports owner" test_ownership_trace_reports_owner
run_test "readme documents ownership" test_readme_documents_ownership
run_test "sbom resource metadata" test_sbom_resource_metadata
run_test "sbom describes component resources" test_sbom_describes_component_resources
run_test "sbom discovered via artifact references" test_sbom_discovered_via_artifact_references
run_test "sbom regenerated at build time" test_sbom_regenerated_at_build_time
run_test "sbom generation is deterministic" test_sbom_generation_is_deterministic
run_test "sbom link is signed" test_sbom_link_is_signed
run_test "readme documents sboms" test_readme_documents_sboms
run_test "product references application" test_product_references_application
run_test "product signature covers reference" test_product_signature_covers_reference
run_test "recursive transfer enforces reference digest" test_recursive_transfer_enforces_reference_digest
run_test "product requires resolvable reference" test_product_requires_resolvable_reference
run_test "make product target" test_make_product_target
run_test "readme documents component references" test_readme_documents_component_references
run_test "versions lists newest first" test_versions_lists_newest_first
run_test "versions constraint filters" test_versions_constraint_filters
run_test "versions latest includes prereleases by default" test_versions_latest_includes_prereleases_by_default
run_test "versions scheme orders build numbers" test_versions_scheme_orders_build_numbers
run_test "versions without scheme misorders" test_versions_without_scheme_misorders
run_test "versions reference requires semver" test_versions_reference_requires_semver
run_test "versions requires ocm 0.19" test_versions_requires_ocm_019
run_test "versions show reports selection" test_versions_show_reports_selection
run_test "make versions target" test_make_versions_target
run_test "readme documents version selection" test_readme_documents_version_selection
run_test "helm chart resource metadata" test_helm_chart_resource_metadata
run_test "helm chart is oci artifact" test_helm_chart_is_oci_artifact
run_test "helm transformer extracts chart" test_helm_transformer_extracts_chart
run_test "helm download verifies chart" test_helm_download_verifies_chart
run_test "helm download requires signature" test_helm_download_requires_signature
run_test "helm build from any directory" test_helm_build_from_any_directory
run_test "helm chart version independent of component" test_helm_chart_version_independent_of_component
run_test "helm chart layer is reproducible" test_helm_chart_layer_is_reproducible
run_test "helm input rejects invalid chart" test_helm_input_rejects_invalid_chart
run_test "helm access resolved at build time" test_helm_access_resolved_at_build_time
run_test "helm transfer keeps chart local" test_helm_transfer_keeps_chart_local
run_test "helm values from component" test_helm_values_from_component
run_test "helm values requires application ctf" test_helm_values_requires_application_ctf
run_test "helm show reports chart" test_helm_show_reports_chart
run_test "make helm target" test_make_helm_target
run_test "readme documents helm charts" test_readme_documents_helm_charts
run_test "wget resource metadata" test_wget_resources_metadata
run_test "wget pinned digest matches upstream file" test_wget_pinned_digest_matches_upstream_file
run_test "wget pinned digest rejects mismatch" test_wget_pinned_digest_rejects_mismatch
run_test "wget input embeds bytes at build time" test_wget_input_embeds_bytes_at_build_time
run_test "wget access needs server at consume time" test_wget_access_needs_server_at_consume_time
run_test "wget download rejects changed upstream" test_wget_download_rejects_changed_upstream
run_test "wget download requires signature" test_wget_download_requires_signature
run_test "wget checksum require rejects unadvertised" test_wget_checksum_require_rejects_unadvertised
run_test "wget checksum matrix" test_wget_checksum_matrix
run_test "wget rejects invalid checksum mode" test_wget_rejects_invalid_checksum_mode
run_test "wget credentials resolved by url identity" test_wget_credentials_resolved_by_url_identity
run_test "wget transfer reference vs copy" test_wget_transfer_reference_vs_copy
run_test "wget transfer copy enforces digest" test_wget_transfer_copy_enforces_digest
run_test "wget requires ocm 0.19" test_wget_requires_ocm_019
run_test "wget server port in use" test_wget_server_port_in_use
run_test "wget show reports resources" test_wget_show_reports_resources
run_test "make wget target" test_make_wget_target
run_test "readme documents http resources" test_readme_documents_http_resources

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
