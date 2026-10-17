#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# Set up golden directory for testing
GOLDEN_DIR="${GOLDEN_DIR:-$ROOT/.test-golden}"

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
  local haystack="$1" needle="$2"
  if ! grep -qF -e "$needle" <<< "$haystack"; then
    echo "  assert_contains failed: '$needle' not found in output" >&2
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

# Builds a CTF from a copy of the component sources. $2 is an optional sed
# expression applied to manifests.yaml and $3 an optional jq filter applied
# to localization.json. Prints the CTF path.
_build_variant() {
  local dir="$1" manifest_expr="$2" loc_filter="$3"
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
  SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567" \
    BUILD_DIR="$dir/variant-build" CTF="$dir/variant-ctf" \
    bash "$repo/scripts/build.sh" >/dev/null
  echo "$dir/variant-ctf"
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
  assert_eq "$resource_names" "deploy-bundle,hello-world-image,hello-world-localization,hello-world-manifests" "resource names"

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

  local rtype relation img
  rtype=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .type')
  assert_eq "$rtype" "ociImage" "image resource type"

  relation=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .relation // "external"')
  assert_eq "$relation" "external" "image relation"

  img=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.imageReference')
  [[ "$img" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "  Image not pinned by digest: $img" >&2; return 1; }

  local expected_digest actual_digest
  expected_digest=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .digest.value')
  actual_digest="${img##*@sha256:}"
  assert_eq "$actual_digest" "$expected_digest" "image digest match"
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
    | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.imageReference')
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
    | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .digest.value')"

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
    | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.imageReference')

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
  for script in build sign publish keys sigstore e2e cluster; do
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

  local relation access img name
  relation=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .relation')
  assert_eq "$relation" "external" "image relation" || return 1
  access=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.type')
  assert_eq "$access" "OCIImage/v1" "image access type" || return 1
  img=$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.imageReference')
  [[ "$img" == docker.io/* ]] || { echo "  image not referenced on docker.io: $img" >&2; return 1; }

  for name in hello-world-manifests hello-world-localization deploy-bundle; do
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

  img_type="$(echo "$plan" | jq -r '.environment[].component.resources[] | select(.name=="hello-world-image") | .access.type')"
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
  assert_eq "$fetched" "hello-world-image" "only the external image is downloaded" || return 1

  # The CTF add transform's spec holds unresolved templates, so match on its label
  added="$(echo "$plan" | jq '[.transformations[] | select(.type=="CTFAddLocalResource/v1alpha1") | select(.label | test("hello-world-image"))] | length')"
  assert_eq "$added" "1" "image written as LocalBlob to the CTF" || return 1
}

test_transfer_copy_resources_uploads_oci_artifact() {
  local tmp="$1" plan ref target_type source_digest target_digest
  _build
  plan="$(_transfer_plan "oci::http://localhost:5001" --copy-resources --upload-as ociArtifact)" || return 1

  # In OCM ≥0.19 imageReference is a CEL template with the target URL embedded as a
  # map-literal key ("baseUrl": "http://localhost:5001"), so we match on the host only.
  ref="$(echo "$plan" | jq -r '.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.imageReference')"
  assert_contains "$ref" "http://localhost:5001" || return 1
  assert_not_contains "$ref" "@sha256:" || return 1

  target_type="$(echo "$plan" | jq -r '.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.access.type')"
  assert_eq "$target_type" "ociArtifact/v1" "target access type" || return 1

  source_digest="$(echo "$plan" | jq -r '.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.resource.digest.value')"
  target_digest="$(echo "$plan" | jq -r '.transformations[] | select(.type=="TransferOCIArtifact/v1alpha1") | .spec.targetResource.digest.value')"
  assert_eq "$target_digest" "$source_digest" "digest preserved across transfer" || return 1
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
run_test "ctf layout is canonical" test_ctf_layout_is_canonical
run_test "ctf archive is portable and signed" test_ctf_archive_is_portable_and_signed
run_test "readme documents canonical component repositories" test_readme_documents_canonical_component_repositories

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
