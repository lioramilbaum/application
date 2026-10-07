#!/usr/bin/env bash
set -euo pipefail
# OCM v0.19.0 hangs on open stdin pipes; close stdin for the whole test process.
exec < /dev/null

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
  if ! grep -qF "$needle" <<< "$haystack"; then
    echo "  assert_contains failed: '$needle' not found in output" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if grep -qF "$needle" <<< "$haystack"; then
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
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/kubectl" <<'EOF'
#!/usr/bin/env bash
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
    [[ "${1:-}" == "clusters" ]] && cat "$(dirname "$0")/../kind-clusters" 2>/dev/null || true
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
esac
EOF
  chmod 0755 "$dir/stub-bin/kind"
  touch "$dir/kind-clusters"
  # stub docker so `require docker` passes
  printf '#!/usr/bin/env bash\n' > "$dir/stub-bin/docker"
  chmod 0755 "$dir/stub-bin/docker"
  echo "$dir/stub-bin"
}

_stub_ocm_unpinned() {
  local dir="$1"
  mkdir -p "$dir/stub-bin"
  cat > "$dir/stub-bin/ocm" <<'OCMEOF'
#!/usr/bin/env bash
# If this is a "get cv ... -o json" call, return descriptor with imageReference unpinned
if [[ "$*" == *"get cv"* ]] && [[ "$*" == *"-o json"* ]]; then
  # Get real output
  REAL_OCM="${REAL_OCM:-ocm}"
  output=$("$REAL_OCM" "$@")
  # Strip @sha256:... from imageReference
  echo "$output" | sed '/imageReference/s/@sha256:[a-f0-9]*//'
else
  # Pass through to real ocm
  REAL_OCM="${REAL_OCM:-ocm}"
  "$REAL_OCM" "$@"
fi
OCMEOF
  chmod 0755 "$dir/stub-bin/ocm"
  echo "$dir/stub-bin"
}

_download_bundle() {
  local dest="$1"
  mkdir -p "$dest/scripts"
  local s
  for s in lib verify manifests deploy; do
    # ocm v0.17 appends to existing output files
    rm -f "$dest/scripts/$s.sh"
    "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
      --identity "name=script-$s" --output "$dest/scripts/$s.sh"
  done
  rm -f "$dest/component-constructor.yaml"
  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" \
    --identity name=component-constructor --output "$dest/component-constructor.yaml"
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
  assert_eq "$resource_names" "component-constructor,hello-world-image,hello-world-manifests,script-deploy,script-lib,script-manifests,script-verify" "resource names"

  local ref_count
  ref_count=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq '.[0].component.componentReferences // [] | length')
  assert_eq "$ref_count" "0" "component references count"

  local provider
  provider=$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" \
    -o json 2>/dev/null | jq -r '.[0].component.provider')
  assert_eq "$provider" "github.com/lioramilbaum" "provider"
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

test_manifests_rejects_unpinned_image() {
  local tmp="$1"
  _build

  local stub_dir real_ocm
  stub_dir=$(_stub_ocm_unpinned "$tmp")
  real_ocm="$OCM"

  # shellcheck disable=SC2097,SC2098
  local out
  if out=$(REAL_OCM="$real_ocm" OCM="$stub_dir/ocm" SKIP_VERIFY=1 \
    bash "$ROOT/scripts/manifests.sh" 2>&1); then
    echo "  Should have failed with unpinned image" >&2
    return 1
  fi

  assert_contains "$out" "not pinned by digest"

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

test_script_resources_metadata() {
  local tmp="$1"
  _build
  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

  local s
  for s in lib verify manifests deploy; do
    local rname="script-$s"
    local rtype mediatype rversion digest expected_digest
    rtype="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .type')"
    mediatype="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .access.mediaType')"
    rversion="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .version')"
    digest="$(echo "$cv_json" | jq -r --arg n "$rname" '.[0].component.resources[] | select(.name==$n) | .digest.value')"
    expected_digest="$(sha256 "$ROOT/scripts/$s.sh")"

    assert_eq "$rtype" "blob" "script-$s type"
    assert_eq "$mediatype" "text/x-shellscript" "script-$s mediaType"
    assert_eq "$rversion" "$VERSION" "script-$s version"
    assert_eq "$digest" "$expected_digest" "script-$s digest"
  done

  local ctype cmedia cdigest cexpected
  ctype="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .type')"
  cmedia="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .access.mediaType')"
  cdigest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="component-constructor") | .digest.value')"
  cexpected="$(sha256 "$ROOT/component-constructor.yaml")"
  assert_eq "$ctype" "blob" "component-constructor type"
  assert_eq "$cmedia" "application/yaml" "component-constructor mediaType"
  assert_eq "$cdigest" "$cexpected" "component-constructor digest"

  # Verify build-time scripts are NOT in the component
  for excl in build sign publish keys e2e cluster; do
    local count
    count="$(echo "$cv_json" | jq -r --arg n "script-$excl" '[.[0].component.resources[] | select(.name==$n)] | length')"
    assert_eq "$count" "0" "script-$excl must be absent"
  done
}

test_script_resources_download_identical() {
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
  grep -qE '^ARG OCM_CLI_VERSION=v[0-9.]+$' "$df" || die "OCM_CLI_VERSION ARG not found in Dockerfile"
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
  jq -e '
    [ .packageRules[]?
      | select((.matchDepNames // []) | index("open-component-model/open-component-model"))
      | .groupName // empty ] | length == 1
  ' "$rv" > /dev/null || die "OCM dependencies are not grouped into one PR"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

run_test "build produces application tree" test_build_produces_application_tree
run_test "image resource is pinned by digest" test_image_resource_is_pinned_by_digest
run_test "manifests resource metadata" test_manifests_resource_metadata
run_test "sign and verify succeed" test_sign_and_verify_succeed
run_test "verify rejects wrong key" test_verify_rejects_wrong_key
run_test "version is propagated" test_version_is_propagated
run_test "manifests renders pinned image" test_manifests_renders_pinned_image
run_test "manifests is idempotent" test_manifests_is_idempotent
run_test "manifests rejects unpinned image" test_manifests_rejects_unpinned_image
run_test "deploy verifies before deploying" test_deploy_verifies_before_deploying
run_test "deploy applies rendered manifests" test_deploy_applies_rendered_manifests
run_test "deploy fails when rollout fails" test_deploy_fails_when_rollout_fails
run_test "script resources metadata" test_script_resources_metadata
run_test "script resources download identical" test_script_resources_download_identical
run_test "bundle is self-contained" test_bundle_is_self_contained
run_test "cluster.sh creates missing cluster" test_cluster_sh_creates_missing_cluster
run_test "cluster.sh reuses existing cluster" test_cluster_sh_reuses_existing_cluster
run_test "cluster.sh down deletes cluster" test_cluster_sh_down_deletes_cluster
run_test "make e2e-run skips build and sign" test_make_e2e_run_skips_build_sign
run_test "devcontainer config is valid" test_devcontainer_config_is_valid
run_test "devcontainer pins tools" test_devcontainer_pins_tools
run_test "renovate updates OCM SHA256 ARGs" test_renovate_updates_ocm_sha256

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
