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
# OCM >= 0.19.0 is needed for Git/v1 input and access.
GIT_OCM="${GIT_OCM:-$OCM}"
GPG_OCM="${GPG_OCM:-$OCM}"
OCI_OCM="${OCI_OCM:-$OCM}"
CREDENTIALS_OCM="${CREDENTIALS_OCM:-$OCM}"
# OCM >= 0.19.0 is needed for --plugin-directory and external plugins.
PLUGIN_OCM="${PLUGIN_OCM:-$OCM}"
REGISTRY_OCM="${REGISTRY_OCM:-$OCM}"
GRAPH_OCM="${GRAPH_OCM:-$OCM}"
GITHUB_OCM="${GITHUB_OCM:-$OCM}"
NORM_OCM="${NORM_OCM:-$OCM}"
S3_OCM="${S3_OCM:-$OCM}"
NONE_OCM="${NONE_OCM:-$OCM}"

PASS=0
FAIL=0
SKIP=0

# A test exits 77 to report SKIP (for example when Docker is unavailable).
run_test() {
  local name="$1" rc=0
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  set +e
  # shellcheck disable=SC2030
  (set -euo pipefail; export BUILD_DIR="$tmp" CTF="$tmp/ctf" DEPLOY_DIR="$tmp/deploy"; "$2" "$tmp")
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  elif [[ $rc -eq 77 ]]; then
    echo "  SKIP: $name"
    SKIP=$((SKIP + 1))
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

# Docs are split between README.md and docs/*.md, so searches cover all of them.
DOC_FILES=("$ROOT/README.md" "$ROOT"/docs/*.md)
# doc_section TITLE: body of the "# TITLE..." or "## TITLE..." section across all doc files (prefix match, fence-aware)
doc_section() {
  awk -v h="$1" 'FNR==1{f=0; c=0} /^(```|~~~)/{ if(!c){c=1; m=substr($0,1,3)} else if(substr($0,1,3)==m){c=0} } !c && /^##? /{t=$0; sub(/^##? /,"",t); f=(index(t,h)==1); next} f' "${DOC_FILES[@]}"
}
doc_heading_exists() { grep -qxF -e "# $1" -e "## $1" "${DOC_FILES[@]}"; }
# _heading_slugs FILE: GitHub-style anchor slug of each heading outside fences
_heading_slugs() {
  awk '/^(```|~~~)/{ if(!c){c=1; m=substr($0,1,3)} else if(substr($0,1,3)==m){c=0}; next } !c && /^#+ /{t=$0; sub(/^#+ /,"",t); s=tolower(t); gsub(/[^a-z0-9 _-]/,"",s); gsub(/ /,"-",s); print s}' "$1"
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

_stub_controller_tools() {
  local dir="$1"
  # helm stub
  cat > "$dir/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$STUB_LOG_DIR/helm.log"
EOF
  chmod +x "$dir/helm"
  # flux stub
  cat > "$dir/flux" <<'EOF'
#!/usr/bin/env bash
echo "flux $*" >> "$STUB_LOG_DIR/flux.log"
EOF
  chmod +x "$dir/flux"
  # kubectl stub (logs args, handles exec by printing Hello, handles apply -f - by tee-ing stdin)
  cat > "$dir/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG_DIR/kubectl.log"
if [[ "$*" == *"-f -"* ]]; then
  tee -a "$STUB_LOG_DIR/kubectl-stdin.log" > /dev/null
fi
if [[ "$*" == *"exec"* ]]; then
  echo "${STUB_EXEC_OUTPUT:-Hello, World!}"
fi
EOF
  chmod +x "$dir/kubectl"
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
  assert_eq "$resource_names" "deploy-bundle,hello-world-config,hello-world-image,hello-world-image,hello-world-kustomize,hello-world-localization,hello-world-manifests,hello-world-rgd,hello-world-sbom" "resource names"

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
  tar_contents="$(tar -tf "$tar_file" | grep -v '/$' | sort | paste -sd, -)"
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

# _renovate_manager FILE_SUBSTR DEPNAME [MATCH_SUBSTR]
# Prints matchStrings[0] of the single customManager matching the given criteria.
# Dies unless exactly one manager matches.
_renovate_manager() {
  local file_sub="$1" depname="$2" match_sub="${3:-}"
  local managers; managers=$(jq -r --arg fs "$file_sub" --arg dn "$depname" --arg ms "$match_sub" '
    [.customManagers[] |
      select(
        ((.managerFilePatterns // []) | any(test($fs))) and
        .depNameTemplate == $dn and
        (if $ms == "" then true else ((.matchStrings // []) | any(test($ms))) end)
      )
    ]
  ' "$ROOT/renovate.json") || die "_renovate_manager: jq failed"
  local count; count=$(echo "$managers" | jq 'length')
  [[ "$count" -eq 1 ]] || die "_renovate_manager: expected 1 manager for depName=$depname file=$file_sub, got $count"
  echo "$managers" | jq -r '.[0].matchStrings[0]'
}

# _renovate_captures RE TEXT
# Prints JSON array of all capture objects found in TEXT.
_renovate_captures() {
  local re="$1" text="$2"
  jq -cn --arg re "$re" --arg s "$text" '[$s | capture($re; "g")]'
}

# _expect_renovate_match RE SAMPLE [EXPECTED_VALUE]
# With EXPECTED_VALUE: asserts exactly one capture with currentValue == EXPECTED_VALUE.
# Without EXPECTED_VALUE: asserts zero captures (negative test).
_expect_renovate_match() {
  local re="$1" sample="$2" expected="${3:-__NO_MATCH__}"
  local caps; caps=$(_renovate_captures "$re" "$sample") || { echo "  jq failed on: $sample" >&2; return 1; }
  local count; count=$(echo "$caps" | jq 'length')
  if [[ "$expected" == "__NO_MATCH__" ]]; then
    [[ "$count" -eq 0 ]] || { echo "  expected no match but got $count for: $sample" >&2; return 1; }
  else
    [[ "$count" -eq 1 ]] || { echo "  expected 1 match but got $count for: $sample" >&2; return 1; }
    local got; got=$(echo "$caps" | jq -r '.[0].currentValue')
    [[ "$got" == "$expected" ]] || { echo "  expected currentValue=$expected but got=$got" >&2; return 1; }
  fi
}

test_renovate_managers_match_targets() {
  local tmp="$1"

  # Build list of repo files (relative paths)
  local files; files=$(find "$ROOT" \( -name .git -o -name build -o -name .test-golden \) -prune -o -type f -print | sed "s|^$ROOT/||" | sort)

  local manager count=0
  while IFS= read -r manager; do
    local file_patterns; file_patterns=$(echo "$manager" | jq -r '.managerFilePatterns[]')
    [[ -n "$file_patterns" ]] || { echo "  manager $(echo "$manager" | jq -r '.depNameTemplate'): managerFilePatterns is empty or missing" >&2; return 1; }
    local match_strings; match_strings=$(echo "$manager" | jq -r '.matchStrings[]')
    local depname; depname=$(echo "$manager" | jq -r '.depNameTemplate')
    local datasource; datasource=$(echo "$manager" | jq -r '.datasourceTemplate')

    # Structural checks
    [[ $(echo "$manager" | jq -r '.customType') == "regex" ]] \
      || { echo "  manager $depname: customType is not regex" >&2; return 1; }
    [[ -n "$depname" && "$depname" != "null" ]] \
      || { echo "  manager: depNameTemplate is missing" >&2; return 1; }
    [[ -n "$datasource" && "$datasource" != "null" ]] \
      || { echo "  manager $depname: datasourceTemplate is missing" >&2; return 1; }
    echo "$match_strings" | grep -q '(?<currentValue>' \
      || { echo "  manager $depname: matchString missing (?<currentValue>" >&2; return 1; }

    # RE2 guard — no lookarounds or backrefs (named groups (?<name> are allowed)
    if echo "$match_strings" | grep -qE '\(\?(=|!|<[=!])|\\[1-9]'; then
      echo "  manager $depname: matchString uses lookaround or backref (not RE2-safe)" >&2; return 1
    fi

    # Each pattern must match at least one repo file
    while IFS= read -r pat; do
      # Strip surrounding /…/
      local re; re=$(echo "$pat" | sed 's|^/||;s|/$||')
      local matches; matches=$(echo "$files" | grep -E "$re" | head -1) || true
      [[ -n "$matches" ]] \
        || { echo "  manager $depname: pattern $pat matches no repo file" >&2; return 1; }
    done < <(echo "$file_patterns")

    count=$((count + 1))
  done < <(jq -c '.customManagers[]' "$ROOT/renovate.json")

  echo "  checked $count custom managers" >&2
}

test_renovate_captures_pinned_versions() {
  local tmp="$1"

  # OCM CLI version
  local re_ocm_cli; re_ocm_cli=$(_renovate_manager "Dockerfile" "open-component-model/open-component-model" "OCM_CLI_VERSION") || return 1
  local expected_ocm; expected_ocm=$(sed -n 's/^ARG OCM_CLI_VERSION=//p' "$ROOT/.devcontainer/Dockerfile" | head -1)
  [[ -n "$expected_ocm" ]] || { echo "  OCM_CLI_VERSION not found in Dockerfile" >&2; return 1; }
  _expect_renovate_match "$re_ocm_cli" "$(cat "$ROOT/.devcontainer/Dockerfile")" "$expected_ocm" || return 1

  # KIND version
  local re_kind; re_kind=$(_renovate_manager "Dockerfile" "kubernetes-sigs/kind") || return 1
  local expected_kind; expected_kind=$(sed -n 's/^ARG KIND_VERSION=//p' "$ROOT/.devcontainer/Dockerfile" | head -1)
  [[ -n "$expected_kind" ]] || { echo "  KIND_VERSION not found in Dockerfile" >&2; return 1; }
  _expect_renovate_match "$re_kind" "$(cat "$ROOT/.devcontainer/Dockerfile")" "$expected_kind" || return 1

  # Flux version in Dockerfile
  local re_flux_df; re_flux_df=$(_renovate_manager "Dockerfile" "fluxcd/flux2") || return 1
  local expected_flux_df; expected_flux_df=$(sed -n 's/^ARG FLUX_VERSION=//p' "$ROOT/.devcontainer/Dockerfile" | head -1)
  [[ -n "$expected_flux_df" ]] || { echo "  FLUX_VERSION not found in Dockerfile" >&2; return 1; }
  _expect_renovate_match "$re_flux_df" "$(cat "$ROOT/.devcontainer/Dockerfile")" "$expected_flux_df" || return 1

  # Helm version in devcontainer.json (the helm feature pin, not the kubectl feature version)
  local re_helm; re_helm=$(_renovate_manager "devcontainer" "helm/helm") || return 1
  local expected_helm; expected_helm=$(jq -r '[.features[] | .helm? // empty] | .[0] // empty' "$ROOT/.devcontainer/devcontainer.json")
  [[ -n "$expected_helm" ]] || { echo "  helm version not found in devcontainer.json" >&2; return 1; }
  _expect_renovate_match "$re_helm" "$(cat "$ROOT/.devcontainer/devcontainer.json")" "$expected_helm" || return 1

  # Flux version in controller.sh
  local re_flux_sh; re_flux_sh=$(_renovate_manager "controller" "fluxcd/flux2") || return 1
  local expected_flux_sh; expected_flux_sh=$(sed -n 's/^FLUX_VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/controller.sh" | head -1)
  [[ -n "$expected_flux_sh" ]] || { echo "  FLUX_VERSION not found in controller.sh" >&2; return 1; }
  _expect_renovate_match "$re_flux_sh" "$(cat "$ROOT/scripts/controller.sh")" "$expected_flux_sh" || return 1

  # OCM controller chart version
  local re_ocm_chart; re_ocm_chart=$(_renovate_manager "controller" "ghcr.io/open-component-model/kubernetes/controller/chart") || return 1
  local expected_ocm_chart; expected_ocm_chart=$(sed -n 's/^OCM_CONTROLLER_CHART_VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/controller.sh" | head -1)
  [[ -n "$expected_ocm_chart" ]] || { echo "  OCM_CONTROLLER_CHART_VERSION not found in controller.sh" >&2; return 1; }
  _expect_renovate_match "$re_ocm_chart" "$(cat "$ROOT/scripts/controller.sh")" "$expected_ocm_chart" || return 1

  # kro chart version
  local re_kro; re_kro=$(_renovate_manager "controller" "kro-run/kro") || return 1
  local expected_kro; expected_kro=$(sed -n 's/^KRO_CHART_VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/controller.sh" | head -1)
  [[ -n "$expected_kro" ]] || { echo "  KRO_CHART_VERSION not found in controller.sh" >&2; return 1; }
  _expect_renovate_match "$re_kro" "$(cat "$ROOT/scripts/controller.sh")" "$expected_kro" || return 1

  # nginx image — must match both amd64 and arm64 lines
  local re_nginx; re_nginx=$(_renovate_manager "component-constructor" "library/nginx") || return 1
  local nginx_lines; nginx_lines=$(grep -oE 'docker\.io/library/nginx:[^@[:space:]]+@sha256:[a-f0-9]{64}' "$ROOT/component-constructor.yaml" || true)
  [[ -n "$nginx_lines" ]] || { echo "  nginx imageReference not found in component-constructor.yaml" >&2; return 1; }
  local nginx_count; nginx_count=$(echo "$nginx_lines" | wc -l | tr -d ' ')
  local caps; caps=$(_renovate_captures "$re_nginx" "$(cat "$ROOT/component-constructor.yaml")") || return 1
  local cap_count; cap_count=$(echo "$caps" | jq 'length')
  [[ "$cap_count" -eq "$nginx_count" ]] || { echo "  nginx: expected $nginx_count captures, got $cap_count" >&2; return 1; }
  # Each capture must have non-empty currentValue and currentDigest
  echo "$caps" | jq -e '[.[] | select(.currentValue == "" or .currentDigest == "")] | length == 0' > /dev/null \
    || { echo "  nginx: empty currentValue or currentDigest in captures" >&2; return 1; }
}

test_renovate_regexes_reject_invalid_input() {
  local tmp="$1"
  local h64; h64=$(python3 -c "print('a'*64)")  # 64-char hex stand-in

  # OCM CLI
  local re; re=$(_renovate_manager "Dockerfile" "open-component-model/open-component-model" "OCM_CLI_VERSION") || return 1
  _expect_renovate_match "$re" "ARG OCM_CLI_VERSION=v1.2.3" "v1.2.3" || return 1
  _expect_renovate_match "$re" "ARG OCM_CLI_VERSION=1.2.3"          || return 1
  _expect_renovate_match "$re" "ARG OCM_CLI_VERSION=latest"         || return 1
  _expect_renovate_match "$re" "ARG OCM_CLI_VERSION=v1.2"          || return 1

  # KIND
  re=$(_renovate_manager "Dockerfile" "kubernetes-sigs/kind") || return 1
  _expect_renovate_match "$re" "ARG KIND_VERSION=v0.1.0" "v0.1.0" || return 1
  _expect_renovate_match "$re" "ARG KIND_VERSION=0.1.0"           || return 1
  _expect_renovate_match "$re" "ARG KIND_SHA256_LINUX_AMD64=$h64"  || return 1

  # Flux in Dockerfile
  re=$(_renovate_manager "Dockerfile" "fluxcd/flux2") || return 1
  _expect_renovate_match "$re" "ARG FLUX_VERSION=v2.9.6" "v2.9.6" || return 1
  _expect_renovate_match "$re" 'FLUX_VERSION="v2.9.6"'            || return 1   # controller.sh form
  _expect_renovate_match "$re" "ARG FLUX_VERSION=2.9.6"          || return 1
  _expect_renovate_match "$re" "ARG FLUX_SHA256_LINUX_AMD64=$h64" || return 1

  # Flux in controller.sh
  re=$(_renovate_manager "controller" "fluxcd/flux2") || return 1
  _expect_renovate_match "$re" 'FLUX_VERSION="v2.9.6"' "v2.9.6"   || return 1
  _expect_renovate_match "$re" "FLUX_VERSION=v2.9.6"               || return 1  # unquoted
  _expect_renovate_match "$re" 'FLUX_VERSION="2.9.6"'              || return 1  # no v prefix
  _expect_renovate_match "$re" "ARG FLUX_VERSION=v2.9.6"           || return 1  # Dockerfile form

  # Helm
  re=$(_renovate_manager "devcontainer" "helm/helm") || return 1
  _expect_renovate_match "$re" '"helm": "4.3.1"' "4.3.1"  || return 1
  _expect_renovate_match "$re" '"helm": "v4.3.1"'         || return 1
  _expect_renovate_match "$re" '"helm": "latest"'         || return 1
  _expect_renovate_match "$re" '"version": "1.37"'        || return 1

  # OCM controller chart
  re=$(_renovate_manager "controller" "ghcr.io/open-component-model/kubernetes/controller/chart") || return 1
  _expect_renovate_match "$re" 'OCM_CONTROLLER_CHART_VERSION="0.19.1"' "0.19.1" || return 1
  _expect_renovate_match "$re" 'OCM_CONTROLLER_CHART_VERSION="v0.19.1"'         || return 1
  _expect_renovate_match "$re" 'OCM_CONTROLLER_CHART_VERSION="0.19"'            || return 1

  # kro
  re=$(_renovate_manager "controller" "kro-run/kro") || return 1
  _expect_renovate_match "$re" 'KRO_CHART_VERSION="v0.9.4"' "v0.9.4" || return 1
  _expect_renovate_match "$re" 'KRO_CHART_VERSION="0.9.4"'           || return 1

  # nginx
  re=$(_renovate_manager "component-constructor" "library/nginx") || return 1
  _expect_renovate_match "$re" "imageReference: docker.io/library/nginx:1.31-alpine@sha256:${h64}" "1.31-alpine" || return 1
  _expect_renovate_match "$re" "imageReference: docker.io/library/nginx:1.31-alpine"               || return 1  # no digest
  _expect_renovate_match "$re" "imageReference: docker.io/library/redis:7@sha256:${h64}"           || return 1  # wrong image
  local h63; h63=$(python3 -c "print('a'*63)")
  _expect_renovate_match "$re" "imageReference: docker.io/library/nginx:1.31-alpine@sha256:${h63}" || return 1  # 63-char digest
}

test_renovate_extract_version_templates() {
  local tmp="$1"

  # OCM chart: uses docker datasource pointing at the OCI registry (no extractVersionTemplate needed)
  local ocm_chart_ds; ocm_chart_ds=$(jq -r '.customManagers[] | select(.depNameTemplate == "ghcr.io/open-component-model/kubernetes/controller/chart" and ((.managerFilePatterns // []) | any(test("controller")))) | .datasourceTemplate' "$ROOT/renovate.json")
  [[ "$ocm_chart_ds" == "docker" ]] || { echo "  OCM chart manager datasourceTemplate: expected docker, got $ocm_chart_ds" >&2; return 1; }

  # Helm: v4.3.1 → 4.3.1
  ev=$(jq -r '.customManagers[] | select(.depNameTemplate == "helm/helm") | .extractVersionTemplate' "$ROOT/renovate.json")
  [[ -n "$ev" && "$ev" != "null" ]] || { echo "  helm manager missing extractVersionTemplate" >&2; return 1; }
  [[ $(echo "$ev" | wc -l | tr -d ' ') -eq 1 ]] || { echo "  ambiguous extractVersionTemplate: expected 1 match, got multiple" >&2; return 1; }
  got=$(jq -rn --arg tag "v4.3.1" --arg re "$ev" '$tag | capture($re) | .version')
  [[ "$got" == "4.3.1" ]] || { echo "  helm extractVersionTemplate: expected 4.3.1, got $got" >&2; return 1; }
  no_match=$(jq -rn --arg tag "4.3.1" --arg re "$ev" 'try ($tag | capture($re) | .version) catch ""' 2>/dev/null || echo "")
  [[ -z "$no_match" ]] || { echo "  helm extractVersionTemplate matched unversioned tag 4.3.1: $no_match" >&2; return 1; }

  # Every github-releases manager whose currentValue lacks a leading v must have extractVersionTemplate
  local missing; missing=$(jq -r '
    .customManagers[] |
    select(
      .datasourceTemplate == "github-releases" and
      ((.matchStrings | join("")) | test("\\?<currentValue>[^v]"))
    ) |
    select(.extractVersionTemplate == null or .extractVersionTemplate == "") |
    .depNameTemplate
  ' "$ROOT/renovate.json")
  [[ -z "$missing" ]] || { echo "  github-releases manager missing extractVersionTemplate: $missing" >&2; return 1; }
}


test_renovate_groups_flux_updates() {
  local tmp="$1"

  # Exactly 2 managers track fluxcd/flux2
  local flux_managers; flux_managers=$(jq '[.customManagers[] | select(.depNameTemplate == "fluxcd/flux2")]' "$ROOT/renovate.json")
  local flux_count; flux_count=$(echo "$flux_managers" | jq 'length')
  [[ "$flux_count" -eq 2 ]] || { echo "  expected 2 flux managers, got $flux_count" >&2; return 1; }

  # One must target Dockerfile, one must target controller.sh
  echo "$flux_managers" | jq -e '[.[].managerFilePatterns[] | test("Dockerfile")] | any' > /dev/null \
    || { echo "  no Flux manager targets Dockerfile" >&2; return 1; }
  echo "$flux_managers" | jq -e '[.[].managerFilePatterns[] | test("controller")] | any' > /dev/null \
    || { echo "  no Flux manager targets controller.sh" >&2; return 1; }

  # group:all ensures all updates, including both Flux managers, land in one PR
  jq -e '(.extends // []) | index("group:all") != null' "$ROOT/renovate.json" > /dev/null \
    || { echo "  group:all not in extends — Flux updates will not be grouped" >&2; return 1; }

  # The two Flux captures must agree (Dockerfile == controller.sh)
  local re_df; re_df=$(_renovate_manager "Dockerfile" "fluxcd/flux2") || return 1
  local re_sh; re_sh=$(_renovate_manager "controller" "fluxcd/flux2") || return 1
  local ver_df; ver_df=$(_renovate_captures "$re_df" "$(cat "$ROOT/.devcontainer/Dockerfile")" | jq -r '.[0].currentValue // empty')
  local ver_sh; ver_sh=$(_renovate_captures "$re_sh" "$(cat "$ROOT/scripts/controller.sh")" | jq -r '.[0].currentValue // empty')
  [[ -n "$ver_df" ]] || { echo "  Flux version not found in Dockerfile" >&2; return 1; }
  [[ -n "$ver_sh" ]] || { echo "  Flux version not found in controller.sh" >&2; return 1; }
  [[ "$ver_df" == "$ver_sh" ]] || { echo "  Flux version drift: Dockerfile=$ver_df controller.sh=$ver_sh" >&2; return 1; }
}

test_renovate_ocm_cli_rule_scoped() {
  local tmp="$1"

  # The controller chart manager in controller.sh must use a different depName from the OCM CLI
  # managers in Dockerfile, so chart and CLI updates are tracked as distinct dependencies.
  local chart_depname; chart_depname=$(jq -r '[.customManagers[] | select((.managerFilePatterns // []) | any(test("controller"))) | select((.matchStrings // []) | any(test("OCM_CONTROLLER_CHART_VERSION")))] | .[0].depNameTemplate' "$ROOT/renovate.json")
  local cli_depname; cli_depname=$(jq -r '[.customManagers[] | select((.managerFilePatterns // []) | any(test("Dockerfile"))) | select((.matchStrings // []) | any(test("OCM_CLI_VERSION")))] | .[0].depNameTemplate' "$ROOT/renovate.json")
  [[ -n "$chart_depname" && "$chart_depname" != "null" ]] || { echo "  OCM controller chart manager not found in controller.sh" >&2; return 1; }
  [[ -n "$cli_depname" && "$cli_depname" != "null" ]] || { echo "  OCM CLI manager not found in Dockerfile" >&2; return 1; }
  [[ "$chart_depname" != "$cli_depname" ]] || { echo "  OCM CLI and chart share depName '$cli_depname' — they cannot be tracked independently" >&2; return 1; }
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
  jq -e '(.extends // []) | index("group:all") != null' "$rv" > /dev/null \
    || die "OCM dependencies are not grouped into one PR"
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

test_publish_rejects_missing_repo_and_config() {
  local tmp="$1" out
  # Missing OCM_REPO
  if out="$(_run_publish_stubbed "$tmp" OCM_REPO="" 2>&1)"; then
    echo "  publish should fail when OCM_REPO is empty" >&2
    return 1
  fi
  assert_contains "$out" "OCM_REPO" || return 1
  [[ ! -f "$tmp/ocm-args.log" ]] || { echo "  ocm was invoked with empty OCM_REPO" >&2; return 1; }

  # Missing TRANSFER_CONFIG file
  if out="$(_run_publish_stubbed "$tmp" TRANSFER_CONFIG="$tmp/missing.ocmconfig" 2>&1)"; then
    echo "  publish should fail when TRANSFER_CONFIG does not exist" >&2
    return 1
  fi
  assert_contains "$out" "TRANSFER_CONFIG" || return 1
  [[ ! -f "$tmp/ocm-args.log" ]] || { echo "  ocm was invoked with missing TRANSFER_CONFIG" >&2; return 1; }
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

  for name in hello-world-manifests hello-world-localization hello-world-rgd hello-world-kustomize hello-world-sbom deploy-bundle; do
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
  section="$(doc_section "Resource repositories")"
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
  section="$(doc_section "Transfer and transport")"
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
  assert_contains "$section" "#signing-and-verification)" || return 1
  assert_contains "$section" "#consuming-the-component)" || return 1
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

  consuming_section="$(doc_section "Consuming the component")"
  assert_contains "$consuming_section" "#transfer-and-transport)" || return 1
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

  # With more than one OCI artifact in the CTF (e.g. hello-world-kustomize alongside the
  # descriptor), the tagged entry is an image index; descend to the descriptor manifest.
  if [[ "$(jq -r .mediaType "$manifest")" == "application/vnd.oci.image.index.v1+json" ]]; then
    digest="$(jq -r '.manifests[] | select(.artifactType=="application/vnd.ocm.software.component-descriptor.v2") | .digest' "$manifest")"
    [[ -n "$digest" ]] || { echo "  no descriptor manifest in index"; return 1; }
    manifest="$CTF/blobs/${digest/:/.}"
    [[ -f "$manifest" ]] || { echo "  descriptor manifest blob missing: $manifest"; return 1; }
  fi
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
  section="$(doc_section "Canonical component repositories")"
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
  section="$(doc_section "Kubernetes controller")"
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
  section="$(doc_section "Kubernetes deployer")"
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
  section="$(doc_section "Plugin system")"
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
  # Some components are tagged with an image index that wraps the descriptor manifest.
  local wrapper=""
  if [[ "$(jq -r '.mediaType' "$out/blobs/${mdigest/:/.}")" == application/vnd.oci.image.index.v1+json ]]; then
    wrapper="$out/blobs/${mdigest/:/.}"
    mdigest="$(jq -r '.manifests[0].digest' "$wrapper")"
  fi
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

  if [[ -n "$wrapper" ]]; then
    jq --arg md "$md" --argjson n "$(wc -c < "$out/blobs/${md/:/.}" | tr -d ' ')" \
      '.manifests[0].digest=$md | .manifests[0].size=$n' "$wrapper" > "$out/new"
    md="sha256:$(sha256 "$out/new")"
    mv "$out/new" "$out/blobs/${md/:/.}"
  fi

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
  section="$(doc_section "Signing and verification")"
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
  assert_contains "$out" "got 9" || return 1

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
  section="$(doc_section "Component identity")"
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
  assert_contains "$section" "#credential-system)" || return 1
  assert_contains "$section" "#signing-and-verification)" || return 1
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

  tree_section="$(doc_section "Component tree")"
  assert_contains "$tree_section" "#component-identity)" || return 1

  consuming_section="$(doc_section "Consuming the component")"
  assert_contains "$consuming_section" "#component-identity)" || return 1
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
  section="$(doc_section "Kubernetes component discovery")"
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
  section="$(doc_section "Ownership")"
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
  assert_contains "$section" "#transfer-and-transport)" || return 1
  assert_contains "$section" "#signing-and-verification)" || return 1

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
hello-world-rgd	components/hello-world/rgd.yaml
hello-world-kustomize	components/hello-world/hello-world-kustomize.oci.tar
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
  section="$(doc_section "Software Bills of Materials")"
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
    "#signing-and-verification)"
    "#transfer-and-transport)"
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
  local section
  section="$(doc_section "Component References")"
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
    "#resolvers)"
    "#canonical-component-repositories)"
    "#signing-and-verification)"
    "#transfer-and-transport)"
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
  resolvers_section="$(doc_section "Resolvers")"
  assert_not_contains "$resolvers_section" "This repository has no \`componentReferences\`" || return 1
  assert_contains "$resolvers_section" "#component-references)" || return 1
}

test_docs_product_page() {
  local page="$ROOT/docs/product.md" content check
  [[ -f "$page" ]] || { echo "  docs/product.md is missing" >&2; return 1; }
  [[ "$(head -n 1 "$page")" == "# Component References" ]] || \
    { echo "  docs/product.md must start with '# Component References'" >&2; return 1; }

  content="$(cat "$page")"
  local checks=(
    "make product"
    "scripts/product.sh"
    "components/product/component-constructor.yaml"
    "build/product-ctf"
    "Trust limitation"
    "github.com/lioramilbaum/application"
  )
  for check in "${checks[@]}"; do
    assert_contains "$content" "$check" "docs/product.md contains: $check" || return 1
  done

  # Moved, not copied: component-graphs.md must no longer carry the section.
  assert_not_contains "$(cat "$ROOT/docs/component-graphs.md")" "## Component References" \
    "component-graphs.md no longer has the Component References section" || return 1

  local readme_section
  readme_section="$(awk '/^### Components and graphs$/{f=1; next} /^#/{f=0} f' "$ROOT/README.md")"
  assert_contains "$readme_section" "](docs/product.md)" \
    "README Components and graphs section links docs/product.md" || return 1
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
  local section
  section="$(doc_section "Version selection")"
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
    "#resolvers)"
    "#kubernetes-controller)"
    "#component-references)"
    "#component-identity)"
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
  id_section="$(doc_section "Component identity")"
  assert_contains "$id_section" "#version-selection)" \
    "Component identity section links to version-selection" || return 1
}


test_docs_versions_page() {
  local page="$ROOT/docs/versions.md" content check
  [[ -f "$page" ]] || { echo "  docs/versions.md is missing" >&2; return 1; }
  [[ "$(head -n 1 "$page")" == "# Version selection" ]] || \
    { echo "  docs/versions.md must start with '# Version selection'" >&2; return 1; }

  content="$(cat "$page")"
  local checks=(
    "make versions"
    "scripts/versions.sh"
    "components/versions/component-constructor.yaml"
    "components/versions/versioning.ocmconfig"
    "--constraint"
    "--latest"
    "build-number"
    "0.19.0"
  )
  for check in "${checks[@]}"; do
    assert_contains "$content" "$check" "docs/versions.md contains: $check" || return 1
  done

  # Moved, not copied: component-graphs.md must no longer carry the section.
  assert_not_contains "$(cat "$ROOT/docs/component-graphs.md")" "## Version selection" \
    "component-graphs.md no longer has the Version selection section" || return 1

  local readme_section
  readme_section="$(awk '/^### Components and graphs$/{f=1; next} /^#/{f=0} f' "$ROOT/README.md")"
  assert_contains "$readme_section" "](docs/versions.md)" \
    "README Components and graphs section links docs/versions.md" || return 1
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
  assert_eq "$(jq -r '.digest.normalisationAlgorithm' <<<"$res")" "ociArtifactDigest/v1" "digest normalisation" || return 1
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
  local section
  section="$(doc_section "Helm charts")"
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
    "#plugin-system)"
    "#signing-and-verification)"
    "#transfer-and-transport)"
    "#version-selection)"
    "#kubernetes-deployer)"
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
  res_section="$(doc_section "Resource repositories")"
  assert_contains "$res_section" "#helm-charts)" "Resource repositories links to helm charts"
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
  local section
  section="$(doc_section "HTTP resources")"
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
    "#resource-repositories)"
    "#signing-and-verification)"
    "#credential-system)"
    "#transfer-and-transport)"
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
  res_section="$(doc_section "Resource repositories")"
  assert_contains "$res_section" "#http-resources)" "Resource repositories links to http resources"
}

_pki_env() {
  local tmp="$1"
  export PKI_DEMO_CTF="$tmp/pki-ctf" PKI_DEMO_OUT="$tmp/pki"
}

_pki_ref() {
  echo "ctf::${1}//github.com/lioramilbaum/pki-demo:${VERSION}"
}

# Prints the fingerprint of the first certificate in PEM file $1.
_pki_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//'
}

test_pki_signature_is_pem_encoded() {
  local tmp="$1" sig value first
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1

  sig="$("$OCM" get cv "$(_pki_ref "$tmp/pki-ctf")" -o json | jq -c '.[0].signatures[] | select(.name=="pki")')"
  [[ -n "$sig" ]] || { echo "  no 'pki' signature on the component" >&2; return 1; }
  assert_eq "$(jq -r '.signature.mediaType' <<<"$sig")" "application/x-pem-file" "signature mediaType" || return 1
  assert_eq "$(jq -r '.signature.algorithm' <<<"$sig")" "RSASSA-PSS" "signature algorithm" || return 1
  assert_eq "$(jq -r '.digest.normalisationAlgorithm' <<<"$sig")" "jsonNormalisation/v4alpha1" "normalisation" || return 1

  value="$(jq -r '.signature.value' <<<"$sig")"
  assert_eq "$(head -n1 <<<"$value")" "-----BEGIN SIGNATURE-----" "first PEM block" || return 1
  assert_eq "$(grep -c -- '-----BEGIN CERTIFICATE-----' <<<"$value")" "2" "embedded certificates" || return 1

  # The first embedded certificate is the leaf; the root is never embedded.
  awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' <<<"$value" > "$tmp/first.pem"
  first="$(_pki_fingerprint "$tmp/first.pem")"
  assert_eq "$first" "$(_pki_fingerprint "$tmp/pki/certs/leaf.crt")" "leaf is first" || return 1
}

test_pki_verifier_pins_only_root() {
  local tmp="$1" cfg subject issuer
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1

  cfg="$(cat "$tmp/pki/verify.ocmconfig")"
  assert_contains "$cfg" "publicKeyPEMFile: $tmp/pki/certs/root.crt" || return 1
  assert_contains "$cfg" "signature: pki" || return 1
  assert_not_contains "$cfg" "privateKeyPEMFile" || return 1
  assert_not_contains "$cfg" "leaf" || return 1
  assert_not_contains "$cfg" "verifier:" || return 1

  subject="$(openssl x509 -in "$tmp/pki/certs/root.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//')"
  issuer="$(openssl x509 -in "$tmp/pki/certs/root.crt" -noout -issuer -nameopt RFC2253 | sed 's/^issuer= *//')"
  assert_eq "$subject" "$issuer" "root is self-signed" || return 1

  assert_contains "$(cat "$tmp/pki/sign.ocmconfig")" "signatureEncodingPolicy: PEM" || return 1
  bash "$ROOT/scripts/pki.sh" verify >/dev/null 2>&1 || { echo "  verify with the root CA failed" >&2; return 1; }
}

test_pki_scenarios() {
  local tmp="$1" out expected
  _pki_env "$tmp"
  out="$(bash "$ROOT/scripts/pki.sh" scenarios 2>/dev/null)" || return 1
  expected="$(printf '%s\n' \
    $'valid\tok\tok\t-' \
    $'rotated-leaf\tok\tok\t-' \
    $'leaf-only-chain\tok\tfail\tunknown-authority' \
    $'verifier-supplies-intermediate\tok\tok\t-' \
    $'rogue-root\tok\tfail\tunknown-authority' \
    $'expired-leaf\tok\tfail\texpired' \
    $'server-auth-leaf\tok\tfail\tkey-usage' \
    $'root-in-chain\tok\tfail\troot-embedded' \
    $'pinned-public-key\tok\tfail\tnot-a-certificate' \
    $'intermediate-as-anchor\tok\tfail\tunknown-authority')"
  assert_eq "$out" "$expected" "scenario matrix"
}

test_pki_rotation_keeps_verifier_config() {
  local tmp="$1"
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" scenarios >/dev/null 2>&1 || return 1

  cmp -s "$tmp/pki/scenarios/rotated-leaf-verify.ocmconfig" "$tmp/pki/verify.ocmconfig" || {
    echo "  rotation changed the verifier config" >&2
    return 1
  }
  local old new
  old="$(openssl x509 -in "$tmp/pki/certs/leaf.crt" -noout -pubkey)"
  new="$(openssl x509 -in "$tmp/pki/certs/leaf2.crt" -noout -pubkey)"
  [[ "$old" != "$new" ]] || { echo "  rotated leaf reuses the old key" >&2; return 1; }
}

test_pki_certs_are_reused() {
  local tmp="$1" before
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" certs >/dev/null 2>&1 || return 1
  before="$(sha256 "$tmp/pki/certs/root.crt")"
  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1
  assert_eq "$(sha256 "$tmp/pki/certs/root.crt")" "$before" "root CA unchanged across runs"
}

test_pki_reissues_expiring_leaf() {
  local tmp="$1" root_before leaf_before
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" scenarios >/dev/null 2>&1 || return 1
  root_before="$(sha256 "$tmp/pki/certs/root.crt")"
  leaf_before="$(_pki_fingerprint "$tmp/pki/certs/leaf.crt")"
  # Simulate a build directory whose leaf has expired.
  cp "$tmp/pki/certs/expired.crt" "$tmp/pki/certs/leaf.crt"
  cp "$tmp/pki/certs/expired.key" "$tmp/pki/certs/leaf.key"

  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || { echo "  make pki failed with an expired leaf on disk" >&2; return 1; }
  assert_eq "$(sha256 "$tmp/pki/certs/root.crt")" "$root_before" "root CA unchanged" || return 1
  [[ "$(_pki_fingerprint "$tmp/pki/certs/leaf.crt")" != "$leaf_before" ]] || { echo "  leaf was not reissued" >&2; return 1; }
  openssl x509 -checkend 86400 -noout -in "$tmp/pki/certs/leaf.crt" >/dev/null || { echo "  reissued leaf is not valid" >&2; return 1; }
}

test_pki_signature_covers_descriptor() {
  local tmp="$1" out
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1

  _tamper_descriptor "$tmp/pki-ctf" "$VERSION" '(.component.provider) = "github.com/someoneelse"' "$tmp/tampered" || return 1
  if out="$(PKI_DEMO_CTF="$tmp/tampered" bash "$ROOT/scripts/pki.sh" verify 2>&1)"; then
    echo "  verify accepted a tampered descriptor" >&2
    return 1
  fi
  assert_contains "$out" "digest mismatch"
}

test_pki_signature_survives_transfer() {
  local tmp="$1"
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1

  "$OCM" transfer cv --config "$tmp/pki/verify.ocmconfig" \
    "$(_pki_ref "$tmp/pki-ctf")" "ctf::$tmp/transferred-ctf" </dev/null >/dev/null 2>&1 || return 1
  "$OCM" verify cv --config "$tmp/pki/verify.ocmconfig" --signature pki \
    "$(_pki_ref "$tmp/transferred-ctf")" </dev/null >/dev/null 2>&1 || {
    echo "  transferred copy does not verify against the root CA" >&2
    return 1
  }
}

test_pki_verify_requires_signature() {
  local tmp="$1" out
  _pki_env "$tmp"
  bash "$ROOT/scripts/pki.sh" build >/dev/null 2>&1 || return 1
  if bash "$ROOT/scripts/pki.sh" verify >/dev/null 2>&1; then
    echo "  verify of an unsigned component should fail" >&2
    return 1
  fi
  if out="$(bash "$ROOT/scripts/pki.sh" show 2>&1)"; then
    echo "  show of an unsigned component should fail" >&2
    return 1
  fi
  assert_contains "$out" "no 'pki' signature"
}

test_pki_own_pki_requires_all_vars() {
  local tmp="$1" out
  _pki_env "$tmp"
  if out="$(PKI_LEAF_KEY="$tmp/leaf.key" bash "$ROOT/scripts/pki.sh" build 2>&1)"; then
    echo "  a partial PKI_* set should fail" >&2
    return 1
  fi
  assert_contains "$out" "set all of PKI_LEAF_KEY, PKI_CHAIN and PKI_ROOT_CERT"
}

test_pki_own_pki_uses_supplied_files() {
  local tmp="$1"
  local own="$tmp/own/certs"
  PKI_DEMO_OUT="$tmp/own" bash "$ROOT/scripts/pki.sh" certs >/dev/null 2>&1 || return 1
  _pki_env "$tmp"

  PKI_LEAF_KEY="$own/leaf.key" PKI_CHAIN="$own/chain.pem" PKI_ROOT_CERT="$own/root.crt" \
    bash "$ROOT/scripts/pki.sh" >/dev/null 2>&1 || return 1

  [[ ! -e "$tmp/pki/certs" ]] || { echo "  demo CA generated despite PKI_* overrides" >&2; return 1; }
  assert_contains "$(cat "$tmp/pki/sign.ocmconfig")" "privateKeyPEMFile: $own/leaf.key" || return 1
  assert_contains "$(cat "$tmp/pki/verify.ocmconfig")" "publicKeyPEMFile: $own/root.crt" || return 1
}

test_pki_show_reports_chain() {
  local tmp="$1" out
  _pki_env "$tmp"
  out="$(bash "$ROOT/scripts/pki.sh" 2>/dev/null)" || return 1
  out="$(bash "$ROOT/scripts/pki.sh" show 2>/dev/null)" || return 1
  assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "4" "show prints 4 lines" || return 1
  assert_contains "$out" $'signature\tpki\tRSASSA-PSS\tapplication/x-pem-file' || return 1
  assert_contains "$out" $'digest\tjsonNormalisation/v4alpha1\tSHA-256\t' || return 1
  assert_contains "$out" $'cert\t0\tCN=OCM Demo Signer\tCN=OCM Demo Intermediate CA' || return 1
  assert_contains "$out" $'cert\t1\tCN=OCM Demo Intermediate CA\tCN=OCM Demo Root CA'
}

test_make_pki_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" pki 2>/dev/null)"
  assert_contains "$dry_run" "scripts/pki.sh" "dry-run includes pki.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "pki" "make help lists pki"
}

test_readme_documents_certificate_chain_signing() {
  local tmp="$1" section check name
  section="$(doc_section "Certificate-chain signing")"
  [[ -n "$section" ]] || { echo "  README missing '## Certificate-chain signing' section" >&2; return 1; }

  local checks=(
    "https://ocm.software/docs/concepts/signing-and-verification/#certificate-chain-trust-pem-encoding"
    "signatureEncodingPolicy: PEM"
    "RSASigningConfiguration/v1alpha1"
    "application/x-pem-file"
    "codeSigning"
    "system trust store"
    "--force"
    "RFC 3161"
    "#3636"
    "revocation"
    "PKI_LEAF_KEY"
    "PKI_CHAIN"
    "PKI_ROOT_CERT"
    "ocm sign cv"
    "ocm verify cv"
    "make pki"
    "build/pki-ctf"
    "#signing-and-verification)"
    "#transfer-and-transport)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/pki/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/pki/component-constructor.yaml" >&2
    return 1
  }

  # Drift guard: every scenario row printed by the script is in the README table.
  _pki_env "$tmp"
  while IFS=$'\t' read -r name _ _ reason; do
    assert_contains "$section" "| \`$name\` |" "scenario $name documented" || return 1
    [[ "$reason" == "-" ]] || assert_contains "$section" "\`$reason\`" "reason $reason documented" || return 1
  done < <(bash "$ROOT/scripts/pki.sh" scenarios 2>/dev/null)

  local sv
  sv="$(doc_section "Signing and verification")"
  assert_contains "$sv" "#certificate-chain-signing)" "Signing and verification links to certificate-chain signing"
}

_git_env() {
  local tmp="$1"
  unset GIT_DEMO_REPO GIT_DEMO_COMMIT GIT_DEMO_REF 2>/dev/null || true
  export GIT_DEMO_CTF="$tmp/git-ctf" GIT_DEMO_OUT="$tmp/git" OCM="$GIT_OCM"
}
_build_git() { _git_env "$1"; bash "$ROOT/scripts/git.sh" build; }
_gitdemo_ref() { echo "ctf::${1}//github.com/lioramilbaum/git-demo:${VERSION}"; }
_gitdemo_json() { "$OCM" get cv "$(_gitdemo_ref "$1")" -o json </dev/null; }
_gitdemo_upstream_commit() { GIT_CONFIG_GLOBAL=/dev/null git --git-dir "$1/git/upstream.git" rev-parse 'v0.1.0^{commit}'; }
_gitdemo_commit_on() {
  local repo="$1" branch="$2" content="$3" work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  GIT_CONFIG_GLOBAL=/dev/null git clone -q "$repo" "$work/w"
  printf '%s\n' "$content" > "$work/w/index.html"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$work/w" -c user.name=test -c user.email=test@example.com commit -q -am "$content"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$work/w" push -q origin "HEAD:refs/heads/$branch"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$work/w" rev-parse HEAD
}
_gitdemo_same_tree() {
  local repo="$1" c
  c="$(GIT_CONFIG_GLOBAL=/dev/null git --git-dir "$repo" -c user.name=test -c user.email=test@example.com \
    commit-tree -m "same tree, other commit" 'v0.1.0^{tree}')"
  GIT_CONFIG_GLOBAL=/dev/null git --git-dir "$repo" update-ref refs/heads/same-tree "$c"
  echo "$c"
}
# _gitdemo_own_commit <dir> <message>: commits all changes in a non-bare repository and prints the commit.
_gitdemo_own_commit() {
  local dir="$1" msg="$2"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$dir" add -A
  GIT_CONFIG_GLOBAL=/dev/null git -C "$dir" -c user.name=test -c user.email=test@example.com commit -q -m "$msg"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$dir" rev-parse HEAD
}
# _gitdemo_own_repo <dir>: non-bare repository holding the demo files; prints its commit.
_gitdemo_own_repo() {
  local dir="$1"
  mkdir -p "$dir"
  GIT_CONFIG_GLOBAL=/dev/null git init -q -b main "$dir"
  cp "$ROOT/components/git/upstream/index.html" "$ROOT/components/git/upstream/build.sh" "$dir/"
  _gitdemo_own_commit "$dir" "hello-world 0.1.0"
}

test_git_resource_metadata() {
  local tmp="$1" json commit src snap trk
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  json="$(_gitdemo_json "$tmp/git-ctf")" || return 1
  commit="$(_gitdemo_upstream_commit "$tmp")"
  src="$(jq -c '.[0].component.sources[] | select(.name=="hello-world-source")' <<<"$json")"
  snap="$(jq -c '.[0].component.resources[] | select(.name=="hello-world-source-snapshot")' <<<"$json")"
  trk="$(jq -c '.[0].component.resources[] | select(.name=="hello-world-source-tracked")' <<<"$json")"

  assert_eq "$(jq -r '.access.type' <<<"$src")" "Git/v1" "source access" || return 1
  assert_eq "$(jq -r '.access.commit' <<<"$src")" "$commit" "source commit" || return 1
  assert_eq "$(jq -r 'has("digest")' <<<"$src")" "false" "source has no digest" || return 1

  assert_eq "$(jq -r '.access.type' <<<"$snap")" "LocalBlob/v1" "snapshot access" || return 1
  assert_eq "$(jq -r '.access.mediaType' <<<"$snap")" "application/x-tgz" "snapshot mediaType" || return 1
  assert_eq "$(jq -r '.labels[] | select(.name=="git.lioramilbaum.github.com/commit" and .signing==true) | .value' <<<"$snap")" \
    "$commit" "snapshot commit label" || return 1

  assert_eq "$(jq -r '.access.type' <<<"$trk")" "Git/v1" "tracked access" || return 1
  assert_eq "$(jq -r '.access.commit' <<<"$trk")" "$commit" "tracked commit pinned" || return 1
  assert_eq "$(jq -r '.digest.hashAlgorithm' <<<"$trk")" "SHA-256" "tracked hashAlgorithm" || return 1
  assert_eq "$(jq -r '.digest.value' <<<"$snap")" "$(jq -r '.digest.value' <<<"$trk")" "snapshot and tracked digests equal"
}

test_git_ref_pinned_at_build_time() {
  local tmp="$1" want
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  # The constructor names a ref for the tracked resource; the commit only exists in the built component.
  if awk '/name: hello-world-source-tracked/{f=1} f' "$ROOT/components/git/component-constructor.yaml" | grep -q 'commit:'; then
    echo "  tracked resource should name a ref, not a commit" >&2
    return 1
  fi
  want="$(_gitdemo_json "$tmp/git-ctf" | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-tracked") | .digest.value')"
  assert_eq "$(_gitdemo_json "$tmp/git-ctf" | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-tracked") | .access.commit')" \
    "$(_gitdemo_upstream_commit "$tmp")" "tracked commit pinned at build time" || return 1

  _gitdemo_commit_on "$tmp/git/upstream.git" main "<p>main moved on</p>" >/dev/null || return 1
  "$OCM" download resource --identity name=hello-world-source-tracked --output "$tmp/tracked.tgz" \
    "$(_gitdemo_ref "$tmp/git-ctf")" </dev/null >/dev/null 2>&1 || {
    echo "  tracked download should survive a moved branch" >&2
    return 1
  }
  assert_eq "$(sha256 "$tmp/tracked.tgz")" "$want" "tracked archive digest after branch moved"
}

test_git_upstream_is_deterministic() {
  local tmp="$1" first second
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  first="$(_gitdemo_json "$tmp/git-ctf" | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-snapshot") | .digest.value')"
  _build_git "$tmp/second" >/dev/null 2>&1 || return 1
  second="$(_gitdemo_json "$tmp/second/git-ctf" | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-snapshot") | .digest.value')"
  assert_eq "$(_gitdemo_upstream_commit "$tmp/second")" "$(_gitdemo_upstream_commit "$tmp")" "upstream commit" || return 1
  assert_eq "$second" "$first" "snapshot digest"
}

test_git_snapshot_matches_commit_tree() {
  local tmp="$1" commit
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  commit="$(_gitdemo_upstream_commit "$tmp")"
  "$OCM" download resource --identity name=hello-world-source-snapshot --output "$tmp/snapshot.tgz" \
    "$(_gitdemo_ref "$tmp/git-ctf")" </dev/null >/dev/null 2>&1 || return 1
  mkdir -p "$tmp/snapshot" "$tmp/archive"
  tar -xzf "$tmp/snapshot.tgz" -C "$tmp/snapshot" || return 1

  [[ -x "$tmp/snapshot/build.sh" ]] || { echo "  build.sh lost its executable bit" >&2; return 1; }

  GIT_CONFIG_GLOBAL=/dev/null git --git-dir "$tmp/git/upstream.git" archive "$commit" | tar -x -C "$tmp/archive" || return 1
  diff -r --exclude='.git' "$tmp/snapshot" "$tmp/archive" >/dev/null || { echo "  snapshot differs from git archive of $commit" >&2; return 1; }
}

test_git_digest_covers_tree_not_commit() {
  local tmp="$1" other
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1

  # A commit with a different tree does not match the recorded archive digest.
  other="$(_gitdemo_commit_on "$tmp/git/upstream.git" other "<p>other tree</p>")"
  _tamper_descriptor "$tmp/git-ctf" "$VERSION" \
    "(.component.resources[] | select(.name==\"hello-world-source-tracked\") | .access.commit) = \"$other\"" \
    "$tmp/other-ctf" || return 1
  local out
  if out="$(GIT_DEMO_CTF="$tmp/other-ctf" bash "$ROOT/scripts/git.sh" download 2>&1)"; then
    echo "  a commit with a different tree should fail to download" >&2
    return 1
  fi
  # Either OCM reports the mismatch internally (archive-mismatch) or our SHA256
  # check catches it (archive does not match the signed digest).
  assert_contains "$out" "archive" || return 1
}

test_git_signature_binds_commit_label() {
  local tmp="$1" fake hex name want filter got
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  fake="$(printf 'a%.0s' {1..40})"
  hex="$(printf 'b%.0s' {1..64})"
  for name in source-commit tracked-commit snapshot-label snapshot-digest tracked-digest; do
    case "$name" in
      source-commit)   want=ok;   filter="(.component.sources[] | select(.name==\"hello-world-source\") | .access.commit) = \"$fake\"" ;;
      tracked-commit)  want=ok;   filter="(.component.resources[] | select(.name==\"hello-world-source-tracked\") | .access.commit) = \"$fake\"" ;;
      snapshot-label)  want=fail; filter="(.component.resources[] | select(.name==\"hello-world-source-snapshot\") | .labels[] | select(.name==\"git.lioramilbaum.github.com/commit\") | .value) = \"$fake\"" ;;
      snapshot-digest) want=fail; filter="(.component.resources[] | select(.name==\"hello-world-source-snapshot\") | .digest.value) = \"$hex\"" ;;
      tracked-digest)  want=fail; filter="(.component.resources[] | select(.name==\"hello-world-source-tracked\") | .digest.value) = \"$hex\"" ;;
    esac
    _tamper_descriptor "$tmp/git-ctf" "$VERSION" "$filter" "$tmp/$name-ctf" || return 1
    if GIT_DEMO_CTF="$tmp/$name-ctf" bash "$ROOT/scripts/git.sh" verify >/dev/null 2>&1; then got=ok; else got=fail; fi
    assert_eq "$got" "$want" "$name verify" || return 1
  done
}

test_git_audit_matches_snapshot() {
  local tmp="$1" commit digest out
  _git_env "$tmp"
  out="$(bash "$ROOT/scripts/git.sh" 2>&1)" || return 1
  commit="$(_gitdemo_upstream_commit "$tmp")"
  digest="$(_gitdemo_json "$tmp/git-ctf" | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-snapshot") | .digest.value')"
  assert_contains "$out" $'audit\t'"$commit"$'\t'"$digest"$'\tmatch'
}

test_git_audit_rejects_wrong_commit_label() {
  local tmp="$1" a b ctor out
  _git_env "$tmp"
  a="$(_gitdemo_own_repo "$tmp/own")"
  printf '<p>second</p>\n' >> "$tmp/own/index.html"
  b="$(_gitdemo_own_commit "$tmp/own" "second")"
  # Label points at the second commit while the snapshot holds the first commit's tree.
  ctor="$tmp/wrong-label.yaml"
  # shellcheck disable=SC2016
  sed -e 's|value: "\${GIT_DEMO_COMMIT}"|value: "'"$b"'"|' "$ROOT/components/git/component-constructor.yaml" > "$ctor"
  export GIT_DEMO_REPO="$tmp/own" GIT_DEMO_COMMIT="$a" GIT_DEMO_CONSTRUCTOR="$ctor"
  bash "$ROOT/scripts/git.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  if out="$(bash "$ROOT/scripts/git.sh" audit 2>&1)"; then
    echo "  audit should reject a label naming another commit" >&2
    return 1
  fi
  assert_contains "$out" "snapshot does not match commit $b"
}

test_git_audit_requires_signature() {
  local tmp="$1" out
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  if out="$(bash "$ROOT/scripts/git.sh" audit 2>&1)"; then
    echo "  audit of an unsigned component should fail" >&2
    return 1
  fi
  assert_not_contains "$out" $'\tmatch'
}

test_git_scenarios() {
  local tmp="$1" out expected
  _git_env "$tmp"
  out="$(bash "$ROOT/scripts/git.sh" scenarios 2>/dev/null)" || return 1
  expected="$(printf '%s\n' \
    $'baseline\tok\tok\tok\t-' \
    $'branch-moved\tok\tok\tok\t-' \
    $'history-rewritten\tok\tok\tfail\tmissing-commit' \
    $'upstream-deleted\tok\tok\tfail\trepository-not-found')"
  assert_eq "$out" "$expected" "scenario matrix"
}

test_git_transfer_carries_snapshot_only() {
  local tmp="$1" out
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/git.sh" transfer 2>&1)" || return 1
  assert_contains "$out" $'source\thello-world-source\tGit/v1' || return 1
  assert_contains "$out" $'resource\thello-world-source-snapshot\tLocalBlob/v1' || return 1
  assert_contains "$out" $'resource\thello-world-source-tracked\tLocalBlob/v1' || return 1

  GIT_DEMO_CTF="$tmp/git/transfer-ctf" bash "$ROOT/scripts/git.sh" verify >/dev/null 2>&1 || {
    echo "  transferred copy should verify" >&2
    return 1
  }

  rm -rf "$tmp/git/upstream.git"
  "$OCM" download resource --identity name=hello-world-source-snapshot --output "$tmp/snapshot.tgz" \
    "$(_gitdemo_ref "$tmp/git/transfer-ctf")" </dev/null >/dev/null 2>&1 || {
    echo "  snapshot should download without the repository" >&2
    return 1
  }
  "$OCM" download resource --identity name=hello-world-source-tracked --output "$tmp/tracked.tgz" \
    "$(_gitdemo_ref "$tmp/git/transfer-ctf")" </dev/null >/dev/null 2>&1 || {
    echo "  tracked resource as LocalBlob should download without the repository" >&2
    return 1
  }
}

test_git_uploader_cannot_copy_git_access() {
  local tmp="$1" cfg out
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  cfg="$tmp/git-transfer.ocmconfig"
  cat > "$cfg" <<'EOF'
type: generic.config.ocm.software/v1
configurations:
  - type: localblob.uploader.transfer.config.ocm.software/v1alpha1
    match: resource.access.isType("Git")
EOF
  "$OCM" transfer cv --config "$cfg" "$(_gitdemo_ref "$tmp/git-ctf")" "ctf::$tmp/git-uploader-ctf" </dev/null >/dev/null 2>&1 || {
    echo "  an uploader rule matching Git/v1 access should succeed" >&2
    return 1
  }
  local trk_type
  trk_type="$("$OCM" get cv "$(_gitdemo_ref "$tmp/git-uploader-ctf")" -o json \
    | jq -r '.[0].component.resources[] | select(.name=="hello-world-source-tracked") | .access.type')"
  assert_eq "$trk_type" "LocalBlob/v1" "tracked converted to LocalBlob" || return 1
}

test_git_own_repo_requires_both_vars() {
  local tmp="$1" out
  _git_env "$tmp"
  if out="$(GIT_DEMO_REPO="$tmp/own" bash "$ROOT/scripts/git.sh" build 2>&1)"; then
    echo "  a repository without a commit should fail" >&2
    return 1
  fi
  assert_contains "$out" "set both GIT_DEMO_REPO and GIT_DEMO_COMMIT, or neither" || return 1
  if out="$(GIT_DEMO_COMMIT="$(printf 'a%.0s' {1..40})" bash "$ROOT/scripts/git.sh" build 2>&1)"; then
    echo "  a commit without a repository should fail" >&2
    return 1
  fi
  assert_contains "$out" "set both GIT_DEMO_REPO and GIT_DEMO_COMMIT, or neither"
}

test_git_own_repo_uses_supplied_repository() {
  local tmp="$1" commit out
  _git_env "$tmp"
  commit="$(_gitdemo_own_repo "$tmp/own")" || return 1
  export GIT_DEMO_REPO="$tmp/own" GIT_DEMO_COMMIT="$commit"
  bash "$ROOT/scripts/git.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/git.sh" audit 2>&1)" || return 1
  assert_contains "$out" $'\tmatch' || return 1
  [[ ! -e "$tmp/git/upstream.git" ]] || { echo "  own repository should not create upstream.git" >&2; return 1; }
}

test_git_rejects_sha256_repository() {
  local tmp="$1" out repo sha256_commit sha1_commit
  _git_env "$tmp"
  sha256_commit="$(printf 'a%.0s' {1..64})"
  export GIT_DEMO_REPO="$tmp/own" GIT_DEMO_COMMIT="$sha256_commit"
  if out="$(bash "$ROOT/scripts/git.sh" build 2>&1)"; then
    echo "  a SHA-256 object name should be rejected" >&2
    return 1
  fi
  assert_contains "$out" "SHA-256 object name" || return 1

  repo="$tmp/sha256-repo"
  GIT_CONFIG_GLOBAL=/dev/null git init -q --object-format=sha256 "$repo"
  printf '<h1>sha256</h1>\n' > "$repo/index.html"
  _gitdemo_own_commit "$repo" "sha256" >/dev/null
  # OCM 0.19.1
  sha1_commit="$(printf 'a%.0s' {1..40})"
  export GIT_DEMO_REPO="$repo" GIT_DEMO_COMMIT="$sha1_commit"
  if out="$(bash "$ROOT/scripts/git.sh" build 2>&1)"; then
    echo "  a SHA-256 repository should be rejected" >&2
    return 1
  fi
  assert_contains "$out" "mismatched algorithms"
}

test_git_requires_ocm_019() {
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
  GIT_OCM="$tmp/fake-ocm"
  _git_env "$tmp"

  if out="$(bash "$ROOT/scripts/git.sh" show 2>&1)"; then
    echo "  git.sh should refuse OCM 0.17.0" >&2
    return 1
  fi
  assert_contains "$out" "requires OCM CLI >= 0.19.0"
}

test_git_show_reports_provenance() {
  local tmp="$1" commit out snap trk
  _build_git "$tmp" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/git.sh" sign >/dev/null 2>&1 || return 1
  commit="$(_gitdemo_upstream_commit "$tmp")"
  out="$(bash "$ROOT/scripts/git.sh" show 2>&1)" || return 1
  assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "3" "show prints 3 lines" || return 1
  snap="$(awk -F'\t' '$2=="hello-world-source-snapshot"{print $6}' <<<"$out")"
  trk="$(awk -F'\t' '$2=="hello-world-source-tracked"{print $6}' <<<"$out")"
  assert_eq "$snap" "$trk" "snapshot and tracked digests equal" || return 1
  assert_contains "$out" $'source\thello-world-source\tGit/v1\t'"$commit"$'\tno\t-' || return 1
  assert_contains "$out" $'resource\thello-world-source-snapshot\tLocalBlob/v1\t'"$commit"$'\tyes\t'"$snap" || return 1
  assert_contains "$out" $'resource\thello-world-source-tracked\tGit/v1\t'"$commit"$'\tno\t'"$trk"
}

test_make_git_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" git 2>/dev/null)"
  assert_contains "$dry_run" "scripts/git.sh" "dry-run includes git.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "git" "make help lists git"
}

test_readme_documents_git_repositories() {
  local tmp="$1" section check name
  section="$(doc_section "Git repositories")"
  [[ -n "$section" ]] || { echo "  README missing '## Git repositories' section" >&2; return 1; }

  local checks=(
    "https://ocm.software/docs/reference/input-and-access-types/#gitv1-input"
    "#gitv1-access"
    "LocalBlob/v1"
    "application/x-tgz"
    "signing: true"
    "source content is recorded without a digest and is not verifiable"
    "git archive digest mismatch"
    "GitCredentials/v1"
    "localblob.uploader.transfer.config.ocm.software/v1alpha1"
    "cannot copy access type Git/v1"
    "#3709"
    "#3794"
    "mismatched algorithms"
    "--object-format=sha1"
    "srcRefs"
    "GIT_DEMO_REPO"
    "GIT_DEMO_COMMIT"
    "GIT_DEMO_REF"
    "make git"
    "build/git-ctf"
    "#source-provenance)"
    "#signing-and-verification)"
    "#transfer-and-transport)"
    "#credential-system)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/git/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/git/component-constructor.yaml" >&2
    return 1
  }

  # Drift guard: every scenario row printed by the script is in the README table.
  _git_env "$tmp"
  while IFS=$'\t' read -r name _ _ _ reason; do
    assert_contains "$section" "| \`$name\` |" "scenario $name documented" || return 1
    [[ "$reason" == "-" ]] || assert_contains "$section" "\`$reason\`" "reason $reason documented" || return 1
  done < <(bash "$ROOT/scripts/git.sh" scenarios 2>/dev/null)
}

_gpg_env() {
  local tmp="$1"
  unset GPG_PRIVATE_KEY GPG_PUBLIC_KEY GPG_KEY_FINGERPRINT 2>/dev/null || true
  export GPG_DEMO_CTF="$tmp/gpg-ctf" GPG_DEMO_OUT="$tmp/gpg" OCM="$GPG_OCM"
}
_build_gpg() { _gpg_env "$1"; bash "$ROOT/scripts/gpg.sh" build; }
_gpg_ref() { echo "ctf::${1}//github.com/lioramilbaum/gpg-demo:${VERSION}"; }

test_gpg_signature_is_openpgp() {
  local tmp="$1" sig value
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  sig="$("$OCM" get cv "$(_gpg_ref "$tmp/gpg-ctf")" -o json </dev/null | jq -c '.[0].signatures[] | select(.name=="gpg")')"
  [[ -n "$sig" ]] || { echo "  no 'gpg' signature on the component" >&2; return 1; }
  assert_eq "$(jq -r '.signature.mediaType' <<<"$sig")" "application/vnd.ocm.signature.gpg" "signature mediaType" || return 1
  assert_eq "$(jq -r '.signature.algorithm' <<<"$sig")" "GPG" "signature algorithm" || return 1
  assert_eq "$(jq -r '.digest.normalisationAlgorithm' <<<"$sig")" "jsonNormalisation/v4alpha1" "normalisation" || return 1
  assert_eq "$(jq -r '.digest.hashAlgorithm' <<<"$sig")" "SHA-256" "digest algorithm" || return 1

  value="$(jq -r '.signature.value' <<<"$sig")"
  assert_eq "$(head -n1 <<<"$value")" "-----BEGIN PGP SIGNATURE-----" "first armor line"
}

test_gpg_configs_pin_signer_key() {
  local tmp="$1" fpr sign_cfg verify_cfg mode
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  fpr="$(cat "$tmp/gpg/keys/signer.fpr")"
  sign_cfg="$(cat "$tmp/gpg/sign.ocmconfig")"
  verify_cfg="$(cat "$tmp/gpg/verify.ocmconfig")"

  assert_contains "$sign_cfg" "GPG/v1alpha1" || return 1
  assert_contains "$sign_cfg" "signature: gpg" || return 1
  assert_contains "$sign_cfg" "keyFingerprint: $fpr" || return 1
  assert_not_contains "$verify_cfg" "privateKeyPGPFile" || return 1
  assert_contains "$verify_cfg" "verifier:" || return 1
  assert_contains "$verify_cfg" "signature: gpg" || return 1

  mode="$(stat -c %a "$tmp/gpg/keys/signer.sec.asc" 2>/dev/null || stat -f %Lp "$tmp/gpg/keys/signer.sec.asc")"
  assert_eq "$mode" "600" "secret key file mode"
}

test_gpg_signs_with_subkey() {
  local tmp="$1" out primary signed
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/gpg.sh" show 2>/dev/null)" || return 1
  primary="$(awk -F'\t' '$1=="key"{print $2}' <<<"$out")"
  signed="$(awk -F'\t' '$1=="signed-by"{print $2}' <<<"$out")"
  [[ -n "$primary" && -n "$signed" ]] || { echo "  show did not report both fingerprints" >&2; return 1; }
  assert_eq "$primary" "$(cat "$tmp/gpg/keys/signer.fpr")" "primary fingerprint" || return 1
  [[ "$signed" != "$primary" ]] || { echo "  signature was made by the primary key, not the signing subkey" >&2; return 1; }
}

test_gpg_keys_are_reused() {
  local tmp="$1"
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" keys >/dev/null 2>&1 || return 1
  cp -R "$tmp/gpg/keys" "$tmp/keys-before"
  bash "$ROOT/scripts/gpg.sh" keys >/dev/null 2>&1 || return 1
  diff -r "$tmp/keys-before" "$tmp/gpg/keys" >/dev/null || { echo "  keys changed across runs" >&2; return 1; }
}

test_gpg_reissues_expiring_key() {
  local tmp="$1" seed seeded_fpr exp
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" keys >/dev/null 2>&1 || return 1

  # Seed a signing subkey that expires in 12 hours, inside the one-day reissue window.
  seed="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$seed"
  exp="$(python3 -I -c 'import time; print(time.strftime("%Y%m%dT%H%M%S", time.localtime(time.time() + 43200)))')"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$seed" \
    --quick-gen-key "OCM Demo Signer <signer@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 2y 2>/dev/null
  seeded_fpr="$(gpg --batch --quiet --homedir "$seed" --with-colons --list-keys "OCM Demo Signer" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$seed" \
    --quick-add-key "$seeded_fpr" rsa3072 sign "$exp" 2>/dev/null
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$seed" \
    --armor --export-secret-keys "$seeded_fpr" > "$tmp/gpg/keys/signer.sec.asc"
  gpg --batch --quiet --homedir "$seed" --armor --export "$seeded_fpr" > "$tmp/gpg/keys/signer.pub.asc"
  echo "$seeded_fpr" > "$tmp/gpg/keys/signer.fpr"
  gpgconf --homedir "$seed" --kill all 2>/dev/null; rm -rf "$seed"

  bash "$ROOT/scripts/gpg.sh" keys >/dev/null 2>&1 || return 1
  [[ "$(cat "$tmp/gpg/keys/signer.fpr")" != "$seeded_fpr" ]] || { echo "  expiring key was not reissued" >&2; return 1; }
}

test_gpg_leaves_user_keyring_untouched() {
  local tmp="$1"
  _gpg_env "$tmp"
  mkdir -p "$tmp/home"
  HOME="$tmp/home" bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  [[ ! -e "$tmp/home/.gnupg" ]] || { echo "  gpg.sh created $tmp/home/.gnupg" >&2; return 1; }
}

test_gpg_scenarios() {
  local tmp="$1" out expected
  _gpg_env "$tmp"
  out="$(bash "$ROOT/scripts/gpg.sh" scenarios 2>/dev/null)" || return 1
  expected="$(printf '%s\n' \
    $'valid\tok\tok\t-' \
    $'rotated-key\tok\tok\t-' \
    $'concatenated-keyring\tok\tok\t-' \
    $'wrong-key\tok\tfail\tunknown-key' \
    $'verifier-pins-other-key\tok\tfail\terror' \
    $'pinned-subkey\tok\tok\t-' \
    $'expired-key\tfail\t-\terror' \
    $'expired-after-signing\tok\tfail\tkey-expired' \
    $'revoked-key\tok\tfail\trevoked' \
    $'protected-key\tok\tok\t-' \
    $'protected-key-no-passphrase\tfail\t-\tpassphrase-required' \
    $'sha512-signature\tok\tok\t-' \
    $'default-verifier\tok\tfail\tmedia-type')"
  assert_eq "$out" "$expected" "scenario matrix"
}

test_gpg_crosscheck_with_stock_gpg() {
  local tmp="$1" out
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/gpg.sh" crosscheck 2>&1)" || return 1
  assert_contains "$out" $'crosscheck\tgood'
}

test_gpg_crosscheck_does_not_cover_descriptor() {
  local tmp="$1" out
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  _tamper_descriptor "$tmp/gpg-ctf" "$VERSION" '(.component.provider) = "github.com/someoneelse"' "$tmp/tampered" || return 1

  out="$(GPG_DEMO_CTF="$tmp/tampered" bash "$ROOT/scripts/gpg.sh" crosscheck 2>&1)" || {
    echo "  crosscheck should pass on a tampered descriptor" >&2
    return 1
  }
  assert_contains "$out" $'crosscheck\tgood' || return 1

  if out="$(GPG_DEMO_CTF="$tmp/tampered" bash "$ROOT/scripts/gpg.sh" verify 2>&1)"; then
    echo "  verify accepted a tampered descriptor" >&2
    return 1
  fi
  assert_contains "$out" "digest mismatch"
}

test_gpg_signature_covers_descriptor() {
  local tmp="$1" out
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  _tamper_descriptor "$tmp/gpg-ctf" "$VERSION" '(.component.resources[] | select(.name=="release-notes") | .name) = "release-renamed"' "$tmp/renamed" || return 1
  if out="$(GPG_DEMO_CTF="$tmp/renamed" bash "$ROOT/scripts/gpg.sh" verify 2>&1)"; then
    echo "  verify accepted a renamed resource" >&2
    return 1
  fi
  assert_contains "$out" "digest mismatch"
}

test_gpg_hash_algorithm_leaves_descriptor_digest() {
  local tmp="$1" sha256_out sha512_out
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" scenarios >/dev/null 2>&1 || return 1
  sha256_out="$(GPG_DEMO_CTF="$tmp/gpg/scenarios/valid-ctf" bash "$ROOT/scripts/gpg.sh" show 2>/dev/null)" || return 1
  sha512_out="$(GPG_DEMO_CTF="$tmp/gpg/scenarios/sha512-signature-ctf" bash "$ROOT/scripts/gpg.sh" show 2>/dev/null)" || return 1
  assert_eq "$(awk -F'\t' '$1=="digest"{print $4}' <<<"$sha512_out")" \
    "$(awk -F'\t' '$1=="digest"{print $4}' <<<"$sha256_out")" "descriptor digest" || return 1
  assert_eq "$(awk -F'\t' '$1=="signed-by"{print $3}' <<<"$sha256_out")" "SHA-256" "default hash" || return 1
  assert_eq "$(awk -F'\t' '$1=="signed-by"{print $3}' <<<"$sha512_out")" "SHA-512" "sha512 hash"
}

test_gpg_multiple_signatures() {
  local tmp="$1" out sigs digests
  _build_gpg "$tmp" >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/gpg.sh" multi 2>/dev/null)" || return 1
  sigs="$(awk -F'\t' '$1=="signature"' <<<"$out" | wc -l | tr -d ' ')"
  assert_eq "$sigs" "2" "signature rows" || return 1
  digests="$(awk -F'\t' '$1=="signature"{print $5}' <<<"$out" | sort -u | wc -l | tr -d ' ')"
  assert_eq "$digests" "1" "signatures cover one digest" || return 1
  assert_contains "$out" $'verify\tscoped\tok\t-' || return 1
  assert_contains "$out" $'verify\tunscoped\tfail\tmedia-type'
}

test_gpg_signature_survives_transfer() {
  local tmp="$1"
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  "$OCM" transfer cv --config "$tmp/gpg/verify.ocmconfig" \
    "$(_gpg_ref "$tmp/gpg-ctf")" "ctf::$tmp/gpg-transferred" </dev/null >/dev/null 2>&1 || return 1
  GPG_DEMO_CTF="$tmp/gpg-transferred" bash "$ROOT/scripts/gpg.sh" verify >/dev/null 2>&1 || {
    echo "  transferred copy does not verify" >&2
    return 1
  }
}

test_gpg_verify_requires_signature() {
  local tmp="$1" out
  _build_gpg "$tmp" >/dev/null 2>&1 || return 1
  if bash "$ROOT/scripts/gpg.sh" verify >/dev/null 2>&1; then
    echo "  verify of an unsigned component should fail" >&2
    return 1
  fi
  if out="$(bash "$ROOT/scripts/gpg.sh" show 2>&1)"; then
    echo "  show of an unsigned component should fail" >&2
    return 1
  fi
  assert_contains "$out" "no 'gpg' signature"
}

test_gpg_download_requires_signature() {
  local tmp="$1"
  _build_gpg "$tmp" >/dev/null 2>&1 || return 1
  if bash "$ROOT/scripts/gpg.sh" download >/dev/null 2>&1; then
    echo "  download of an unsigned component should fail" >&2
    return 1
  fi
  [[ ! -e "$tmp/gpg/download/release-notes" ]] || { echo "  unsigned component was downloaded" >&2; return 1; }
}

test_gpg_download_checks_digest() {
  local tmp="$1" content
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/gpg.sh" download >/dev/null 2>&1 || return 1
  content="$(cat "$tmp/gpg/download/release-notes")"
  assert_eq "$content" "github.com/lioramilbaum/gpg-demo $VERSION" "downloaded content"
}

test_gpg_own_keys_require_both_vars() {
  local tmp="$1" out
  _gpg_env "$tmp"
  if out="$(GPG_PRIVATE_KEY="$tmp/signer.sec.asc" bash "$ROOT/scripts/gpg.sh" build 2>&1)"; then
    echo "  a private key without a public key should fail" >&2
    return 1
  fi
  assert_contains "$out" "set both GPG_PRIVATE_KEY and GPG_PUBLIC_KEY, or neither" || return 1
  if out="$(GPG_PUBLIC_KEY="$tmp/signer.pub.asc" bash "$ROOT/scripts/gpg.sh" build 2>&1)"; then
    echo "  a public key without a private key should fail" >&2
    return 1
  fi
  assert_contains "$out" "set both GPG_PRIVATE_KEY and GPG_PUBLIC_KEY, or neither"
}

test_gpg_own_keys_use_supplied_files() {
  local tmp="$1" own
  own="$tmp/own"
  GPG_DEMO_OUT="$own" bash "$ROOT/scripts/gpg.sh" keys >/dev/null 2>&1 || return 1
  _gpg_env "$tmp"
  GPG_PRIVATE_KEY="$own/keys/signer.sec.asc" GPG_PUBLIC_KEY="$own/keys/signer.pub.asc" \
    bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1

  [[ ! -e "$tmp/gpg/keys/signer.sec.asc" ]] || { echo "  demo keys generated despite GPG_PRIVATE_KEY" >&2; return 1; }
  assert_contains "$(cat "$tmp/gpg/sign.ocmconfig")" "privateKeyPGPFile: $own/keys/signer.sec.asc" || return 1
  assert_contains "$(cat "$tmp/gpg/verify.ocmconfig")" "publicKeyPGPFile: $own/keys/signer.pub.asc"
}

test_gpg_show_reports_key() {
  local tmp="$1" out
  _gpg_env "$tmp"
  bash "$ROOT/scripts/gpg.sh" >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/gpg.sh" show 2>/dev/null)" || return 1
  assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "4" "show prints 4 lines" || return 1
  assert_contains "$out" $'signature\tgpg\tGPG\tapplication/vnd.ocm.signature.gpg' || return 1
  assert_contains "$out" $'digest\tjsonNormalisation/v4alpha1\tSHA-256\t' || return 1
  assert_contains "$out" $'key\t' || return 1
  assert_contains "$out" $'signed-by\t'
}

test_make_gpg_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" gpg 2>/dev/null)"
  assert_contains "$dry_run" "scripts/gpg.sh" "dry-run includes gpg.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "gpg" "make help lists gpg"
}

test_readme_documents_gpg_signing() {
  local tmp="$1" section check name
  section="$(doc_section "GPG signing")"
  [[ -n "$section" ]] || { echo "  README missing '## GPG signing' section" >&2; return 1; }

  # The README spells the path literally as prose, so the tilde must not expand here.
  # shellcheck disable=SC2088
  local checks=(
    "https://ocm.software/docs/tutorials/signing/gpg/"
    "GPG/v1alpha1"
    "GPGCredentials/v1alpha1"
    "GPGSigningConfiguration/v1alpha1"
    "[C]"
    "[S]"
    "/tmp"
    "~/.gnupg"
    "make gpg"
    "build/gpg-ctf"
    "signer.sec.asc"
    "application/vnd.ocm.signature.gpg"
    "digest mismatch"
    "crosscheck"
    "--signature gpg"
    "unsupported media type"
    "GPG_PRIVATE_KEY"
    "GPG_PUBLIC_KEY"
    "passphrase"
    "#3858"
    "#3691"
    "#transfer-and-transport)"
    "#signing-and-verification)"
    "#credential-system)"
    "#certificate-chain-signing)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/gpg/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/gpg/component-constructor.yaml" >&2
    return 1
  }

  # Drift guard: every scenario row printed by the script is in the README table.
  _gpg_env "$tmp"
  while IFS=$'\t' read -r name _ _ reason; do
    assert_contains "$section" "| \`$name\` |" "scenario $name documented" || return 1
    [[ "$reason" == "-" ]] || assert_contains "$section" "\`$reason\`" "reason $reason documented" || return 1
  done < <(bash "$ROOT/scripts/gpg.sh" scenarios 2>/dev/null)

  local sv
  sv="$(doc_section "Signing and verification")"
  assert_contains "$sv" "#gpg-signing)" "Trust models link to GPG signing"
}

_oci_env() {
  local tmp="$1"
  export OCI_DEMO_CTF="$tmp/oci-ctf" OCI_DEMO_OUT="$tmp/oci" OCM="$OCI_OCM"
}

_build_oci() {
  bash "$ROOT/scripts/oci.sh" build 2>/dev/null
}

_oci_ref() {
  echo "ctf::$OCI_DEMO_CTF//github.com/lioramilbaum/oci-demo:$VERSION"
}

test_oci_layout_is_reproducible() {
  local tmp="$1" f
  mkdir -p "$tmp/layouts"
  python3 "$ROOT/components/oci/layout.py" "$tmp/layouts" || return 1
  for f in hello-oci-amd64.oci.tar hello-oci-arm64.oci.tar hello-oci-multiarch.oci.tar; do
    cmp -s "$tmp/layouts/$f" "$ROOT/components/oci/$f" \
      || { echo "  $f differs from a fresh run of layout.py" >&2; return 1; }
  done
}

test_oci_image_resource_metadata() {
  local tmp="$1" rows
  _oci_env "$tmp"
  _build_oci || return 1
  rows="$("$OCM" get cv "$(_oci_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[] | [.name, .type, .relation, (.extraIdentity.architecture // "-")] | @tsv')"
  assert_contains "$rows" $'hello-image\tociImage\tlocal\tamd64' "amd64 image" || return 1
  assert_contains "$rows" $'hello-image\tociImage\tlocal\tarm64' "arm64 image" || return 1
  assert_contains "$rows" $'hello-image-multiarch\tociImage\tlocal\t-' "multi-arch index" || return 1
}

test_oci_resource_digest_is_manifest_digest() {
  local tmp="$1" digest
  _oci_env "$tmp"
  _build_oci || return 1
  digest="$("$OCM" get cv "$(_oci_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name=="hello-image" and .extraIdentity.architecture=="amd64") | .digest.value')"
  mkdir -p "$tmp/src"
  tar -xf "$ROOT/components/oci/hello-oci-amd64.oci.tar" -C "$tmp/src" || return 1
  assert_eq "$(jq -r '.manifests[0].digest' "$tmp/src/index.json")" "sha256:$digest" "manifest digest" || return 1
}

test_oci_download_yields_oci_layout() {
  local tmp="$1" dir
  _oci_env "$tmp"
  _build_oci || return 1
  bash "$ROOT/scripts/oci.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/oci.sh" download >/dev/null 2>&1 || return 1
  dir="$tmp/oci/download/hello-image-amd64"
  [[ -f "$dir/oci-layout" ]] || { echo "  missing oci-layout" >&2; return 1; }
  [[ -f "$dir/index.json" ]] || { echo "  missing index.json" >&2; return 1; }
  [[ -d "$dir/blobs/sha256" ]] || { echo "  missing blobs/sha256" >&2; return 1; }
}

test_oci_multiarch_index_references_variants() {
  local tmp="$1" digest index
  _oci_env "$tmp"
  _build_oci || return 1
  bash "$ROOT/scripts/oci.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/oci.sh" download >/dev/null 2>&1 || return 1
  digest="$("$OCM" get cv "$(_oci_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name=="hello-image-multiarch") | .digest.value')"
  # The downloaded root index is the one whose digest is the resource digest.
  index="$tmp/oci/download/hello-image-multiarch/blobs/sha256/$digest"
  assert_eq "$(jq '.manifests | length' "$index")" "2" "variants in index" || return 1
  assert_eq "$(jq -r '[.manifests[].platform.architecture] | sort | join(",")' "$index")" "amd64,arm64" "platforms" || return 1
}

test_oci_download_requires_signature() {
  local tmp="$1"
  _oci_env "$tmp"
  _build_oci || return 1
  if bash "$ROOT/scripts/oci.sh" download >/dev/null 2>&1; then
    echo "  download of an unsigned component succeeded" >&2
    return 1
  fi
  [[ ! -e "$tmp/oci/download" ]] || { echo "  download left output behind" >&2; return 1; }
}

test_oci_signature_covers_image_digest() {
  local tmp="$1" filter work err
  _oci_env "$tmp"
  _build_oci || return 1
  bash "$ROOT/scripts/oci.sh" sign >/dev/null 2>&1 || return 1
  filter='(.component.resources[] | select(.name=="hello-image" and .extraIdentity.architecture=="amd64") | .digest.value) = "0000000000000000000000000000000000000000000000000000000000000000"'
  work="$tmp/tampered"
  _tamper_descriptor "$OCI_DEMO_CTF" "$VERSION" "$filter" "$work" || return 1
  assert_fails env OCI_DEMO_CTF="$work" bash "$ROOT/scripts/oci.sh" verify >/dev/null 2>"$tmp/verify.err" || return 1
  err="$(cat "$tmp/verify.err")"
  assert_contains "$err" "digest mismatch" "verify rejects tampered image digest" || return 1
}

test_oci_plan_copy_resources_leaves_local_images() {
  local tmp="$1" plan row
  _oci_env "$tmp"
  _build_oci || return 1
  plan="$(bash "$ROOT/scripts/oci.sh" plan 2>/dev/null)" || return 1
  row="$(awk -F'\t' '$1=="copy-resources"{print $2}' <<<"$plan")"
  assert_contains "$row" "OCIAddLocalResource/v1alpha1=3" "local images stay local" || return 1
  assert_not_contains "$row" "AddOCIArtifact" || return 1
}

test_oci_plan_uploader_rewrites_references() {
  local tmp="$1" plan row types refs
  _oci_env "$tmp"
  _build_oci || return 1
  plan="$(bash "$ROOT/scripts/oci.sh" plan 2>/dev/null)" || return 1
  row="$(awk -F'\t' '$1=="uploader"{print $2}' <<<"$plan")"
  assert_contains "$row" "AddOCIArtifact/v1alpha1=3" "uploader uploads each image" || return 1
  types="$(jq -r '.transformations[] | select(.type=="AddOCIArtifact/v1alpha1") | .spec.resource.access.type' "$tmp/oci/plan-uploader.json")"
  assert_eq "$(sort -u <<<"$types")" "ociArtifact/v1" "access type" || return 1
  refs="$(jq -r '.transformations[] | select(.type=="AddOCIArtifact/v1alpha1") | .spec.resource.access.imageReference' "$tmp/oci/plan-uploader.json")"
  assert_contains "$refs" "/hello-image:" "image reference rewritten" || return 1
}

test_oci_transfer_to_ctf_keeps_digests() {
  local tmp="$1" query src dst
  _oci_env "$tmp"
  _build_oci || return 1
  query='.[0].component.resources[] | [.name, (.extraIdentity.architecture // "-"), .digest.value] | @tsv'
  "$OCM" transfer cv "$(_oci_ref)" "ctf::$tmp/oci-copy-ctf" </dev/null >/dev/null 2>&1 || return 1
  src="$("$OCM" get cv "$(_oci_ref)" -o json </dev/null | jq -r "$query")"
  dst="$("$OCM" get cv "ctf::$tmp/oci-copy-ctf//github.com/lioramilbaum/oci-demo:$VERSION" -o json </dev/null | jq -r "$query")"
  assert_eq "$dst" "$src" "digests after transfer" || return 1
}

test_oci_inspect_reports_architectures() {
  local tmp="$1" out
  _oci_env "$tmp"
  _build_oci || return 1
  bash "$ROOT/scripts/oci.sh" sign >/dev/null 2>&1 || return 1
  out="$(bash "$ROOT/scripts/oci.sh" inspect 2>/dev/null)" || return 1
  assert_contains "$out" $'image\thello-image\tamd64\t' "amd64 row" || return 1
  assert_contains "$out" $'image\thello-image\tarm64\t' "arm64 row" || return 1
  assert_contains "$out" $'image\thello-image-multiarch\tmultiarch\t' "multi-arch row" || return 1
  assert_contains "$out" $'layer\thello-image\tarm64\t' "arm64 layer row" || return 1
}

test_localization_relocate_rewrites_access_keeps_digest() {
  local tmp="$1" out
  _oci_env "$tmp"
  _build_oci || return 1
  out="$(bash "$ROOT/scripts/oci.sh" relocate 2>/dev/null)" || return 1
  assert_eq "$(awk -F'\t' '$1=="after" && $4=="ociArtifact/v1"' <<<"$out" | wc -l | tr -d ' ')" "3" "after rows" || return 1
  assert_eq "$(awk -F'\t' '$1=="after" && $5==""' <<<"$out" | wc -l | tr -d ' ')" "0" "after rows with empty imageReference" || return 1
  assert_eq "$(awk -F'\t' '$1=="after"{print $2, $3}' <<<"$out")" \
    "$(awk -F'\t' '$1=="before"{print $2, $3}' <<<"$out")" "name and arch pairs after relocation" || return 1
  assert_eq "$(awk -F'\t' '$1=="before"{b[++n]=$5} $1=="after"{a[++m]=$5} END{for(i=1;i<=m;i++) if(a[i]==b[i]) c++; print c+0}' <<<"$out")" \
    "0" "imageReference rewritten for every resource" || return 1
}

test_localization_readme_documents_three_levels() {
  local check
  for check in "Build time" "Transfer time" "Deploy time" "does NOT substitute"; do
    assert_contains "$(cat "${DOC_FILES[@]}")" "$check" "README documents: $check" || return 1
  done
}

test_make_oci_target() {
  local tmp="$1"

  local dry_run
  dry_run="$(make -s --dry-run -C "$ROOT" oci 2>/dev/null)"
  assert_contains "$dry_run" "scripts/oci.sh" "dry-run includes oci.sh" || return 1

  local help_out
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "oci" "make help lists oci"
}

test_readme_documents_oci_images() {
  local section
  section="$(doc_section "OCI images")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## OCI images' section" >&2; return 1; }

  local checks=(
    "ociImage"
    "extraIdentity"
    "hello-image-multiarch"
    "relocate.ocmconfig"
    "layout.py"
    "#transfer-and-transport)"
    "make oci"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: first README yaml block (minus # lines) must match the constructor.
  local readme_yaml constructor_yaml
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/oci/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/oci/component-constructor.yaml" >&2
    return 1
  }

  local res_section
  res_section="$(doc_section "Resource repositories")"
  assert_contains "$res_section" "#oci-images)" "Resource repositories links to OCI images"
}

# _credentials_env <tmp>
_credentials_env() {
  export CREDENTIALS_DEMO_CTF="$1/credentials-ctf" \
         CREDENTIALS_DEMO_OUT="$1/credentials" \
         OCM="$CREDENTIALS_OCM"
}

test_credentials_build_creates_ctf() {
  local tmp="$1"
  _credentials_env "$tmp"
  bash "$ROOT/scripts/credentials.sh" build >/dev/null || return 1

  local cv_json name res_names access digest
  cv_json="$("$OCM" get cv "ctf::$CREDENTIALS_DEMO_CTF//github.com/lioramilbaum/credentials-demo:$VERSION" -o json)" || return 1
  name="$(jq -r '.[0].component.name' <<<"$cv_json")"
  assert_eq "$name" "github.com/lioramilbaum/credentials-demo" "component name" || return 1
  res_names="$(jq -r '[.[0].component.resources[].name] | join(",")' <<<"$cv_json")"
  assert_eq "$res_names" "hello-image" "resource names" || return 1
  access="$(jq -r '.[0].component.resources[0].access.type' <<<"$cv_json")"
  assert_eq "$access" "LocalBlob/v1" "access type" || return 1
  digest="$(jq -r '.[0].component.resources[0].digest.value' <<<"$cv_json")"
  [[ -n "$digest" && "$digest" != "null" ]] || { echo "  digest missing" >&2; return 1; }
}

test_credentials_show_lists_consumer_types() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" show)" || return 1
  assert_contains "$out" $'identity\tOCIRegistry' || return 1
  assert_contains "$out" $'identity\tWget' || return 1
  assert_contains "$out" $'identity\tHelmChartRepository' || return 1
  assert_not_contains "$out" "OCIRegistryCredentials" || return 1
  assert_not_contains "$out" "GitHubAccessToken"
}

test_credentials_match_exact_wins_over_wildcard() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" match)" || return 1
  assert_contains "$out" $'exact-over-wildcard\tWget\tteam-a/report.txt\texact' || return 1
  assert_contains "$out" $'exact-over-wildcard-reversed\tWget\tteam-a/report.txt\texact'
}

test_credentials_match_wildcard_catches_subpath() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" match)" || return 1
  assert_contains "$out" $'wildcard-subpath\tWget\tteam-a/report.txt\tteam-a-wild' || return 1
  assert_contains "$out" $'type-alias\tWget\tteam-a/report.txt\thttp-alias'
}

test_credentials_match_path_star_does_not_cross_slash() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" match)" || return 1
  assert_contains "$out" $'star-not-across-slash\tWget\tteam-a/nested/report.txt\tnone' || return 1
  assert_contains "$out" $'star-per-segment\tWget\tteam-a/nested/report.txt\tteam-a-nested'
}

test_credentials_chain_combines_configs() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" chain)" || return 1
  assert_contains "$out" $'two-files/team-a\tteam-a/report.txt\tfile-a' || return 1
  assert_contains "$out" $'two-files/team-b\tteam-b/report.txt\tfile-b' || return 1
  assert_contains "$out" $'later-file-wins/forward\tteam-a/report.txt\tfile-b-override' || return 1
  assert_contains "$out" $'later-file-wins/reversed\tteam-a/report.txt\tfile-a' || return 1
  assert_contains "$out" $'stdin\tteam-b/report.txt\tfile-b'
}

test_credentials_wget_identity_hostname_required() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" match)" || return 1
  assert_contains "$out" $'hostname-missing\tWget\tteam-a/report.txt\tnone' || return 1
  assert_contains "$out" $'hostname-not-resolved\tWget\tteam-a/report.txt\tnone' || return 1
  assert_contains "$out" $'no-path-matches-all\tWget\tteam-a/nested/report.txt\thost'
}

test_credentials_wget_identity_port_attribute() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" match)" || return 1
  assert_contains "$out" $'port-omitted\tWget\tteam-a/report.txt\tnone' || return 1
  assert_contains "$out" $'port-mismatch\tWget\tteam-a/report.txt\tnone' || return 1
  assert_contains "$out" $'scheme-omitted\tWget\tteam-a/report.txt\tno-scheme' || return 1
  assert_contains "$out" $'scheme-mismatch\tWget\tteam-a/report.txt\tnone'
}

test_credentials_generic_config_wraps_multiple() {
  local tmp="$1" out
  _credentials_env "$tmp"
  out="$(bash "$ROOT/scripts/credentials.sh" chain)" || return 1
  assert_contains "$out" $'generic-flat/team-a\tteam-a\tflat-a' || return 1
  assert_contains "$out" $'generic-flat/team-b\tteam-b\tflat-b' || return 1
  assert_contains "$out" $'generic-nested/result\tresult\tnone' || return 1
  assert_contains "$(cat "$tmp/credentials/chain/generic-nested/stderr")" "nested generic"
}

test_credentials_scenarios_matrix_output() {
  local tmp="$1" out row overlap_rows bad
  _credentials_env "$tmp"
  bash "$ROOT/scripts/credentials.sh" build >/dev/null || return 1
  out="$(bash "$ROOT/scripts/credentials.sh" scenarios)" || return 1

  local want=(
    $'oci-host\tOCIRegistry\tteam-a\thost\thost'
    $'oci-path-exact\tOCIRegistry\tteam-a\texact\texact'
    $'oci-path-glob\tOCIRegistry\tteam-a\tglob\tglob'
    $'oci-path-other\tOCIRegistry\tteam-a\tother\tnone'
    $'oci-star-not-across-slash\tOCIRegistry\tteam-a/nested\tstar\tnone'
    $'oci-exact-over-glob\tOCIRegistry\tteam-a\texact|glob\texact'
    $'type-mismatch-wget\tOCIRegistry\tteam-a\twget-user\tnone'
    $'type-mismatch-oci\tWget\tteam-a/report.txt\toci-user\tnone'
    $'duplicate-identity\tOCIRegistry\tteam-a\tfirst|second\tsecond'
    $'typed-over-generic\tWget\tteam-a/report.txt\ttyped|direct\ttyped'
    $'generic-credentials\tWget\tteam-a/report.txt\tgeneric\tgeneric'
  )
  for row in "${want[@]}"; do
    assert_contains "$out" "$row" || return 1
  done

  # Overlapping wildcards pick randomly, so only check that each probe picked a candidate.
  overlap_rows="$(awk -F'\t' '$1=="overlap-wildcards"' <<<"$out")"
  assert_eq "$(wc -l <<<"$overlap_rows" | tr -d ' ')" "10" "overlap probe count" || return 1
  bad="$(awk -F'\t' '$1=="overlap-wildcards" && $5!="host" && $5!="team-a-wild"' <<<"$out")"
  assert_eq "$bad" "" "overlap selections are candidates"
}

test_make_credentials_target() {
  local tmp="$1" dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" credentials 2>/dev/null)"
  assert_contains "$dry_run" "scripts/credentials.sh" "dry-run includes credentials.sh" || return 1

  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "credentials" "make help lists credentials"
}

test_readme_documents_credential_system() {
  local section
  section="$(doc_section "Credential system")"
  [[ -n "$section" ]] || \
    { echo "  README missing '## Credential system' section" >&2; return 1; }

  local checks=(
    "### Consumer identities"
    "### Matching"
    "WgetCredentials/v1"
    "OCICredentials/v1"
    "path.Match"
    "nested generic configurations"
  )
  local check
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block under ### Demo must be the constructor, byte for byte.
  local demo demo_yaml constructor_yaml
  demo="$(awk '/^### Demo/{f=1;next} /^### |^## /{f=0} f' <<<"$section")"
  demo_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$demo")"
  constructor_yaml="$(cat "$ROOT/components/credentials/component-constructor.yaml")"
  [[ "$demo_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block under ### Demo differs from components/credentials/component-constructor.yaml" >&2
    return 1
  }
}

# ── Plugin demo ──────────────────────────────────────────────────────────────

# _plugin_env <tmp>
_plugin_env() {
  export PLUGIN_DEMO_CTF="$1/plugin-ctf" \
         PLUGIN_DEMO_OUT="$1/plugin" \
         PLUGIN_DIR="$1/plugins" \
         OCM="$PLUGIN_OCM"
}

# _plugin_ref <ctf>
_plugin_ref() {
  echo "ctf::${1}//github.com/lioramilbaum/plugin-demo:${VERSION}"
}

test_plugin_capabilities_returns_access_type() {
  local tmp="$1" caps t required
  _plugin_env "$tmp"
  caps="$(python3 -I -S "$ROOT/components/plugin/demo-store/demo-store-plugin" capabilities)" || return 1
  for t in resourceRepository digestProcessorRepository; do
    jq -e --arg t "$t" \
      '.capabilities[] | select(.type==$t) | .supportedAccessTypes[] | select(.type=="demo-store/v1alpha1")' \
      <<<"$caps" >/dev/null || { echo "  $t does not serve demo-store/v1alpha1" >&2; return 1; }
  done
  required="$(jq -r '.capabilities[0].supportedAccessTypes[0].jsonSchema' <<<"$caps" | base64 -d \
    | jq -r '.required | join(",")')" || return 1
  assert_contains "$required" "storeId" || return 1
  assert_contains "$required" "blobId"
}

test_plugin_healthz_responds() {
  local tmp="$1" out
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" install >/dev/null || return 1
  out="$(bash "$ROOT/scripts/plugin.sh" probe)" || return 1
  assert_contains "$out" $'healthz\t200' || return 1
  assert_contains "$out" $'location\thttp+unix://'
}

test_plugin_build_registers_access_type() {
  local tmp="$1" cv r digest
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  cv="$("$OCM" --plugin-directory "$PLUGIN_DIR" get cv "$(_plugin_ref "$PLUGIN_DEMO_CTF")" -o json)" || return 1
  r="$(jq -c '.[0].component.resources[] | select(.name=="demo-blob")' <<<"$cv")"
  assert_eq "$(jq -r .access.type <<<"$r")" "demo-store/v1alpha1" "access type" || return 1
  assert_eq "$(jq -r .relation <<<"$r")" "external" "relation" || return 1
  assert_eq "$(jq -r .digest.normalisationAlgorithm <<<"$r")" "genericBlobDigest/v1" "normalisation" || return 1
  digest="$(jq -r .digest.value <<<"$r")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "  demo-blob has no sha256 digest: '$digest'" >&2; return 1; }
}

test_plugin_download_returns_blob() {
  local tmp="$1" path i
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  path="$(bash "$ROOT/scripts/plugin.sh" download)" || return 1
  printf 'hello from demo-store\n' | cmp -s - "$path" || { echo "  downloaded blob differs" >&2; return 1; }
  # The plugin exits once its parent (ocm) is gone; poll for that instead of sleeping.
  # shellcheck disable=SC2034
  for i in $(seq 1 30); do
    pgrep -f "$PLUGIN_DIR/demo-store-plugin" >/dev/null || return 0
    sleep 0.1
  done
  echo "  demo-store plugin still running 3s after download" >&2
  return 1
}

test_plugin_identity_endpoint() {
  local tmp="$1" out identity
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" install >/dev/null || return 1
  out="$(bash "$ROOT/scripts/plugin.sh" probe)" || return 1
  identity="$(awk -F'\t' '$1=="identity"{print $2}' <<<"$out")"
  assert_eq "$(jq -Sc . <<<"$identity")" \
    "$(jq -Sc . <<<'{"identity":{"storeId":"my-store","type":"demo-store/v1alpha1"}}')" "identity row" || return 1
  out="$(bash "$ROOT/scripts/plugin.sh" scenarios no-credentials)" || return 1
  assert_contains "$out" "unauthorized"
}

test_plugin_missing_plugin_fails_gracefully() {
  local tmp="$1" out
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  mkdir -p "$tmp/empty"
  if out="$(PLUGIN_DIR="$tmp/empty" bash "$ROOT/scripts/plugin.sh" download 2>&1)"; then
    echo "  download without the plugin should fail" >&2
    return 1
  fi
  assert_contains "$out" "failed to get plugin for typ" || return 1
  [[ ! -e "$tmp/plugin/download" ]] || { echo "  download directory left behind" >&2; return 1; }
  # build installs the plugin into PLUGIN_DIR itself, so it registers even from an empty directory
  PLUGIN_DIR="$tmp/empty" bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  [[ -x "$tmp/empty/demo-store-plugin" ]] || { echo "  build did not install the plugin" >&2; return 1; }
}

test_plugin_show_lists_capabilities() {
  local tmp="$1" out
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  out="$(bash "$ROOT/scripts/plugin.sh" show)" || return 1
  assert_contains "$out" $'capability\tresourceRepository\tdemo-store/v1alpha1' || return 1
  assert_contains "$out" $'capability\tdigestProcessorRepository\tdemo-store/v1alpha1' || return 1
  assert_contains "$out" $'registered\tdemo-store-plugin\t' || return 1
  assert_contains "$out" $'resource\tdemo-blob\tdemo-store/v1alpha1'
}

test_plugin_scenarios_correct_response() {
  local tmp="$1" out expected
  _plugin_env "$tmp"
  out="$(bash "$ROOT/scripts/plugin.sh" scenarios correct missing-plugin config-locations \
    unknown-blob invalid-spec no-credentials)" || return 1
  expected="$(printf '%s\n' \
    $'correct\tok\tok\t-' \
    $'missing-plugin\tfail\t-\tno-plugin' \
    $'config-locations\tfail\t-\tno-plugin' \
    $'unknown-blob\tfail\t-\tnot-found' \
    $'invalid-spec\tfail\t-\tinvalid-spec' \
    $'no-credentials\tfail\t-\tunauthorized')"
  assert_eq "$out" "$expected" "scenario rows"
}

test_plugin_scenarios_malformed_response() {
  local tmp="$1" out expected
  _plugin_env "$tmp"
  out="$(bash "$ROOT/scripts/plugin.sh" scenarios malformed-capabilities malformed-response \
    plugin-error unsupported-location tampered-content)" || return 1
  expected="$(printf '%s\n' \
    $'malformed-capabilities\tfail\t-\tbad-capabilities' \
    $'malformed-response\tfail\t-\tmalformed-response' \
    $'plugin-error\tfail\t-\tplugin-error' \
    $'unsupported-location\tfail\t-\tunsupported-location' \
    $'tampered-content\tok\tfail\tdigest-mismatch')"
  assert_eq "$out" "$expected" "scenario rows"
}

test_plugin_loglevel_debug_shows_registration() {
  local tmp="$1" err
  _plugin_env "$tmp"
  bash "$ROOT/scripts/plugin.sh" build >/dev/null || return 1
  err="$("$OCM" --plugin-directory "$PLUGIN_DIR" --loglevel debug get cv "$(_plugin_ref "$PLUGIN_DEMO_CTF")" \
    2>&1 >/dev/null)" || return 1
  assert_contains "$err" 'msg="discovered plugin" id=demo-store-plugin' || return 1
  assert_contains "$err" 'msg="adding resource repository plugin"' || return 1
  assert_contains "$err" 'msg="adding digest processor plugin"'
}

test_make_plugin_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" plugin 2>/dev/null)"
  assert_contains "$dry_run" "scripts/plugin.sh" "dry-run includes plugin.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "plugin" "make help lists plugin"
}

test_readme_documents_plugin_demo() {
  local section block expected check
  section="$(doc_section "Plugin system")"
  [[ -n "$section" ]] || { echo "  README missing '## Plugin system' section" >&2; return 1; }

  local checks=(
    "/healthz"
    "/identity"
    "/resource/get"
    "/resource/digest/process"
    "http+unix://"
    "supportedAccessTypes"
    "jsonSchema"
    "Authorization"
    "make plugin"
    "components/plugin/demo-store/demo-store-plugin"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" || return 1
  done

  # The first YAML block in the section is the demo constructor, without its comment line.
  block="$(awk '/^```yaml/{f=1;next} /^```/{if (f) exit} f' <<<"$section")"
  expected="$(grep -v '^#' "$ROOT/components/plugin/component-constructor.yaml")"
  assert_eq "$block" "$expected" "demo component YAML block"
}

# ── Local OCI registry ──────────────────────────────────────────────────────

_docker_available() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

_registry_env() {
  export REGISTRY_DEMO_CTF="$1/registry-ctf" \
         REGISTRY_DEMO_OUT="$1/registry" \
         OCM="$REGISTRY_OCM" \
         REGISTRY_NAME=ocm-demo-registry-test \
         REGISTRY_HOST=127.0.0.1 \
         REGISTRY_PORT="${REGISTRY_TEST_PORT:-5056}" \
         REGISTRY_PATH=ocm
}

# Starts an empty registry on the test port; returns 77 (SKIP) without Docker.
_registry_fresh() {
  _docker_available || { echo "  skip: docker not available"; return 77; }
  _registry_env "$1"
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  trap 'docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true' EXIT
  bash "$ROOT/scripts/registry.sh" start >/dev/null
}

_registry_ref() {
  echo "oci::http://${REGISTRY_HOST:-127.0.0.1}:${REGISTRY_PORT:-5056}/ocm//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}"
}

_registry_ctf_ref() {
  echo "ctf::${REGISTRY_DEMO_CTF}//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}"
}

_registry_pulled_ref() {
  echo "ctf::${REGISTRY_DEMO_OUT}/pulled-ctf//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}"
}

test_registry_docker_available() {
  local tmp="$1" stub err
  grep -qE 'registry:2@sha256:[0-9a-f]{64}' "$ROOT/scripts/registry.sh" || \
    { echo "  registry.sh does not pin registry:2 by digest" >&2; return 1; }

  # A docker that cannot reach a daemon must make the demo skip with exit 0.
  stub="$tmp/docker-stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/docker"
  chmod +x "$stub/docker"
  err="$tmp/skip.err"
  PATH="$stub:$PATH" bash "$ROOT/scripts/registry.sh" >/dev/null 2>"$err" || \
    { echo "  registry.sh should exit 0 without Docker" >&2; return 1; }
  assert_contains "$(cat "$err")" "skip: Docker is not available" || return 1
  if docker inspect ocm-demo-registry >/dev/null 2>&1; then
    echo "  container ocm-demo-registry should not exist" >&2
    return 1
  fi
}

test_registry_start_creates_container() {
  local tmp="$1" id_before id_after
  _registry_fresh "$tmp" || return $?
  assert_eq "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME")" "true" "container running" || return 1
  assert_contains "$(docker port "$REGISTRY_NAME" 5000/tcp)" ":5056" "port published" || return 1
  curl -fsS "http://127.0.0.1:5056/v2/" >/dev/null || { echo "  registry not reachable" >&2; return 1; }
  id_before="$(docker inspect -f '{{.Id}}' "$REGISTRY_NAME")"
  bash "$ROOT/scripts/registry.sh" start >/dev/null || return 1
  id_after="$(docker inspect -f '{{.Id}}' "$REGISTRY_NAME")"
  assert_eq "$id_after" "$id_before" "second start keeps the container"
}

test_registry_push_component_to_registry() {
  local tmp="$1" catalog tags
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  catalog="$(curl -fsS "http://127.0.0.1:5056/v2/_catalog")" || return 1
  assert_contains "$catalog" "component-descriptors/github.com/lioramilbaum/registry-demo" "catalog lists component" || return 1
  tags="$(curl -fsS "http://127.0.0.1:5056/v2/ocm/component-descriptors/github.com/lioramilbaum/registry-demo/tags/list")" || return 1
  assert_contains "$tags" '"0.1.0"' "tag 0.1.0"
}

test_registry_get_cv_from_registry() {
  local tmp="$1" cv show
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  cv="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null)" || return 1
  assert_eq "$(jq -r '.[0].component.name' <<<"$cv")" "github.com/lioramilbaum/registry-demo" "name" || return 1
  assert_eq "$(jq -r '.[0].component.version' <<<"$cv")" "${VERSION:-0.1.0}" "version" || return 1
  assert_eq "$(jq -r '.[0].component.provider' <<<"$cv")" "github.com/lioramilbaum" "provider" || return 1
  show="$(bash "$ROOT/scripts/registry.sh" show 2>/dev/null)" || return 1
  assert_contains "$show" $'component\tgithub.com/lioramilbaum/registry-demo' "show component row" || return 1
  assert_contains "$show" $'resource\trelease-notes' "show resource row"
}

test_registry_sign_in_registry() {
  local tmp="$1" sigs ctf_sigs out
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" sign >/dev/null 2>&1 || return 1

  sigs="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null | jq -r '[.[0].signatures[]?.name] | join(",")')" || return 1
  assert_eq "$sigs" "default" "registry descriptor signature" || return 1

  ctf_sigs="$("$OCM" get cv "$(_registry_ctf_ref)" -o json 2>/dev/null | jq -r '(.[0].signatures // []) | length')" || return 1
  assert_eq "$ctf_sigs" "0" "source CTF stays unsigned" || return 1

  if out="$(bash "$ROOT/scripts/registry.sh" sign 2>&1)"; then
    echo "  second sign should fail" >&2
    return 1
  fi
  assert_contains "$out" "already exists" || return 1
}

test_registry_verify_signed_component() {
  local tmp="$1" wrong out
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" verify >/dev/null 2>&1 || { echo "  verify should pass" >&2; return 1; }

  wrong="$(_wrong_verify_config "$tmp")"
  if out="$(VERIFY_CONFIG="$wrong" bash "$ROOT/scripts/registry.sh" verify 2>&1)"; then
    echo "  verify with wrong key should fail" >&2
    return 1
  fi
  assert_contains "$out" "SIGNATURE VERIFICATION FAILED"
}

test_registry_pull_downloads_resource() {
  local tmp="$1" desc actual
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" pull >/dev/null 2>&1 || return 1

  assert_eq "$(cat "$REGISTRY_DEMO_OUT/download/release-notes")" \
    "github.com/lioramilbaum/registry-demo ${VERSION:-0.1.0}" "release notes content" || return 1
  desc="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null | jq -r '.[0].component.resources[] | select(.name=="release-notes") | .digest.value')" || return 1
  actual="$(shasum -a 256 "$REGISTRY_DEMO_OUT/download/release-notes" | cut -d' ' -f1)"
  assert_eq "$actual" "$desc" "downloaded sha256 matches descriptor" || return 1

  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
    "$(_registry_pulled_ref)" </dev/null >/dev/null 2>&1 || { echo "  pulled CTF should verify" >&2; return 1; }
}

test_registry_stop_removes_container() {
  local tmp="$1"
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" stop >/dev/null || return 1
  if docker inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
    echo "  container should be removed by stop" >&2
    return 1
  fi
  if curl -fsS "http://127.0.0.1:5056/v2/" >/dev/null 2>&1; then
    echo "  registry should not answer after stop" >&2
    return 1
  fi
  bash "$ROOT/scripts/registry.sh" stop >/dev/null || { echo "  second stop should exit 0" >&2; return 1; }
  bash "$ROOT/scripts/registry.sh" start >/dev/null || return 1
  # Registry data is lost with the container, so the component is gone.
  if "$OCM" get cv "$(_registry_ref)" -o json >/dev/null 2>&1 </dev/null; then
    echo "  component should not survive stop and start" >&2
    return 1
  fi
}

test_registry_push_idempotent() {
  local tmp="$1" tags sigs out
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  tags="$(curl -fsS "http://127.0.0.1:5056/v2/ocm/component-descriptors/github.com/lioramilbaum/registry-demo/tags/list" | jq -c '.tags')" || return 1
  assert_eq "$tags" '["0.1.0"]' "one tag after two pushes" || return 1

  bash "$ROOT/scripts/registry.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  # OCM 0.19.1: re-pushing from the unsigned CTF drops the registry signature.
  sigs="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null | jq -r '(.[0].signatures // []) | length')" || return 1
  assert_eq "$sigs" "0" "re-push drops signature" || return 1

  if out="$(bash "$ROOT/scripts/registry.sh" verify 2>&1)"; then
    echo "  verify should fail after re-push" >&2
    return 1
  fi
}

test_registry_transfer_preserves_resources() {
  local tmp="$1" jq_digest jq_sig ctf_digest reg_digest pulled_digest reg_sig pulled_sig
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" sign >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" pull >/dev/null 2>&1 || return 1

  jq_digest='.[0].component.resources[] | select(.name=="release-notes") | .digest.value'
  ctf_digest="$("$OCM" get cv "$(_registry_ctf_ref)" -o json 2>/dev/null | jq -r "$jq_digest")" || return 1
  reg_digest="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null | jq -r "$jq_digest")" || return 1
  pulled_digest="$("$OCM" get cv "$(_registry_pulled_ref)" -o json 2>/dev/null | jq -r "$jq_digest")" || return 1
  assert_eq "$reg_digest" "$ctf_digest" "registry resource digest" || return 1
  assert_eq "$pulled_digest" "$ctf_digest" "pulled resource digest" || return 1

  jq_sig='.[0].signatures[] | select(.name=="default") | .digest.value'
  reg_sig="$("$OCM" get cv "$(_registry_ref)" -o json 2>/dev/null | jq -r "$jq_sig")" || return 1
  pulled_sig="$("$OCM" get cv "$(_registry_pulled_ref)" -o json 2>/dev/null | jq -r "$jq_sig")" || return 1
  assert_eq "$pulled_sig" "$reg_sig" "pulled signature digest"
}

test_registry_unsigned_verify_fails() {
  local tmp="$1" out
  _registry_fresh "$tmp" || return $?
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1

  if out="$(bash "$ROOT/scripts/registry.sh" verify 2>&1)"; then
    echo "  verify should fail on an unsigned component" >&2
    return 1
  fi
  assert_contains "$out" "no signatures found" || return 1

  if bash "$ROOT/scripts/registry.sh" pull >/dev/null 2>&1; then
    echo "  pull should fail on an unsigned component" >&2
    return 1
  fi
  if [[ -e "$REGISTRY_DEMO_OUT/download" ]]; then
    echo "  no download should be left after a failed pull" >&2
    return 1
  fi
}

test_registry_oci_url_format() {
  local tmp="$1" out
  _registry_fresh "$tmp" || return $?
  out="$(bash "$ROOT/scripts/registry.sh" start 2>/dev/null)" || return 1
  assert_eq "$out" "oci::http://127.0.0.1:5056/ocm" "start prints repository" || return 1
  bash "$ROOT/scripts/registry.sh" build >/dev/null 2>&1 || return 1
  bash "$ROOT/scripts/registry.sh" push >/dev/null 2>&1 || return 1

  # Without http:// OCM assumes HTTPS and fails.
  if out="$("$OCM" get cv "oci::127.0.0.1:5056/ocm//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}" -o json 2>&1 </dev/null)"; then
    echo "  scheme-less oci:: URL should fail" >&2
    return 1
  fi
  assert_contains "$out" "https://" "scheme-less URL falls back to https" || return 1

  # The http:// scheme alone is enough without the oci:: prefix.
  "$OCM" get cv "http://127.0.0.1:5056/ocm//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}" -o json >/dev/null 2>&1 </dev/null || \
    { echo "  http:// URL without oci:: should succeed" >&2; return 1; }

  # Another path is another, empty repository.
  if "$OCM" get cv "oci::http://127.0.0.1:5056/other//github.com/lioramilbaum/registry-demo:${VERSION:-0.1.0}" -o json >/dev/null 2>&1 </dev/null; then
    echo "  component under another path should not exist" >&2
    return 1
  fi
}

test_make_registry_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" registry 2>/dev/null)" || return 1
  assert_contains "$dry_run" "scripts/registry.sh" "dry-run includes registry.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)" || return 1
  assert_contains "$help_out" "registry" "make help lists registry" || return 1
  assert_contains "$help_out" "Docker" "make help mentions Docker"
}

test_readme_documents_local_oci_registry() {
  local section check readme_yaml constructor_yaml

  doc_heading_exists "Local OCI registry" || \
    { echo "  README missing '## Local OCI registry' heading" >&2; return 1; }
  section="$(doc_section "Local OCI registry")"

  local checks=(
    "oci::http://127.0.0.1:5055/ocm"
    "component-descriptors"
    "ocm transfer cv"
    "ocm sign cv"
    "ocm verify cv"
    "ocm get cv"
    "ocm download resource"
    "registry:2@sha256:"
    "make registry"
    "scripts/registry.sh stop"
    "already exists"
    "#credential-system)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block must match the constructor written by scripts/registry.sh.
  readme_yaml="$(awk '/^```yaml/{n++; f=(n==1); next} /^```/{f=0} f' <<<"$section")"
  constructor_yaml="$(sed -n "/<<'REGISTRY_CONSTRUCTOR_EOF'/,/^REGISTRY_CONSTRUCTOR_EOF\$/p" "$ROOT/scripts/registry.sh" | sed '1d;$d')"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from the constructor in scripts/registry.sh" >&2
    return 1
  }
}

# ── Component graphs ─────────────────────────────────────────────────────────

# _graph_env <tmp>
_graph_env() {
  export GRAPH_DEMO_OUT="$1/graph" OCM="$GRAPH_OCM"
}

# _graph_build <tmp>: builds the three CTFs; output goes to a log so failures are visible.
_graph_build() {
  _graph_env "$1"
  bash "$ROOT/scripts/graph.sh" build </dev/null >"$1/graph-build.log" 2>&1 \
    || { tail -n 20 "$1/graph-build.log" >&2; return 1; }
}

# A resolver config with no entries, so a probe cannot fall back to any repository.
_graph_empty_config() {
  printf 'type: generic.config.ocm.software/v1\nconfigurations: []\n' > "$1"
}

# _graph_transfer <tmp>: builds the CTFs, then writes the flat and recursive transfer targets.
_graph_transfer() {
  _graph_build "$1" || return 1
  bash "$ROOT/scripts/graph.sh" transfer </dev/null >"$1/graph-transfer.log" 2>&1 \
    || { tail -n 20 "$1/graph-transfer.log" >&2; return 1; }
}

_graph_platform_ref() {
  echo "ctf::$GRAPH_DEMO_OUT/platform-ctf//github.com/lioramilbaum/graph/platform:$VERSION"
}

test_graph_references_span_three_repositories() {
  local tmp="$1" refs
  _graph_build "$tmp" || return 1
  assert_eq "$(jq -r '[.artifacts[].repository] | unique | sort | join(",")' "$GRAPH_DEMO_OUT/base-ctf/artifact-index.json")" \
    "component-descriptors/github.com/lioramilbaum/graph/runtime" "base CTF holds runtime only" || return 1
  assert_eq "$(jq -r '[.artifacts[].repository] | unique | sort | join(",")' "$GRAPH_DEMO_OUT/apps-ctf/artifact-index.json")" \
    "component-descriptors/github.com/lioramilbaum/graph/backend,component-descriptors/github.com/lioramilbaum/graph/frontend" \
    "apps CTF holds frontend and backend only" || return 1
  assert_eq "$(jq -r '[.artifacts[].repository] | unique | sort | join(",")' "$GRAPH_DEMO_OUT/platform-ctf/artifact-index.json")" \
    "component-descriptors/github.com/lioramilbaum/graph/platform" "platform CTF holds platform only" || return 1
  refs="$("$OCM" get cv "$(_graph_platform_ref)" -o json </dev/null \
    | jq -r '[.[0].component.componentReferences[] | select((.digest.value // "") != "")] | length')"
  assert_eq "$refs" "2" "platform has 2 references with a digest" || return 1
}

test_graph_recursive_get_walks_all_levels() {
  local tmp="$1" names
  _graph_build "$tmp" || return 1
  names="$("$OCM" get cv "$(_graph_platform_ref)" --recursive \
    --config "$GRAPH_DEMO_OUT/resolvers.ocmconfig" -o json </dev/null \
    | jq -r '[.[].component.name | split("/") | last] | sort | join(" ")')"
  # OCM does not deduplicate on multiple reference paths: the diamond reaches runtime
  # twice, so it is listed twice by design.
  assert_eq "$names" "backend frontend platform runtime runtime" "recursive get lists the diamond" || return 1
}

test_graph_resolver_order_first_match_wins() {
  local tmp="$1" reversed="$1/graph/reversed-resolvers.ocmconfig"
  _graph_build "$tmp" || return 1
  cat > "$reversed" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: CommonTransportFormat/v1
          filePath: $GRAPH_DEMO_OUT/apps-ctf
          accessMode: readonly
        componentNamePattern: github.com/lioramilbaum/graph/*
      - repository:
          type: CommonTransportFormat/v1
          filePath: $GRAPH_DEMO_OUT/base-ctf
          accessMode: readonly
        componentNamePattern: github.com/lioramilbaum/graph/runtime
EOF
  assert_fails "$OCM" get cv "$(_graph_platform_ref)" --recursive --config "$reversed" -o json \
    </dev/null >/dev/null 2>&1 || return 1
}

test_graph_recursive_transfer_collects_graph() {
  local tmp="$1" empty="$1/graph/empty.ocmconfig"
  _graph_transfer "$tmp" || return 1
  _graph_empty_config "$empty"
  assert_eq "$(jq '[.artifacts[].repository] | unique | length' "$GRAPH_DEMO_OUT/release-ctf/artifact-index.json")" \
    "4" "release CTF holds four repositories" || return 1
  "$OCM" get cv "ctf::$GRAPH_DEMO_OUT/release-ctf//github.com/lioramilbaum/graph/platform:$VERSION" \
    --recursive --config "$empty" -o json </dev/null >/dev/null 2>&1 \
    || { echo "  recursive transfer target is not self-contained" >&2; return 1; }
}

test_graph_flat_transfer_is_not_self_contained() {
  local tmp="$1" empty="$1/graph/empty.ocmconfig"
  _graph_transfer "$tmp" || return 1
  _graph_empty_config "$empty"
  assert_eq "$(jq '[.artifacts[].repository] | unique | length' "$GRAPH_DEMO_OUT/flat-ctf/artifact-index.json")" \
    "1" "flat CTF holds one repository" || return 1
  assert_fails "$OCM" get cv "ctf::$GRAPH_DEMO_OUT/flat-ctf//github.com/lioramilbaum/graph/platform:$VERSION" \
    --recursive --config "$empty" -o json </dev/null >/dev/null 2>&1 || return 1
}

test_graph_plan_uploads_shared_reference_once() {
  local tmp="$1" uploads runtime_fetches
  _graph_build "$tmp" || return 1
  bash "$ROOT/scripts/graph.sh" plan </dev/null >/dev/null 2>&1 || return 1
  uploads="$(jq '[.transformations[] | select(.type == "CTFAddComponentVersion/v1alpha1")] | length' "$GRAPH_DEMO_OUT/plan.json")"
  assert_eq "$uploads" "4" "plan has one upload per component" || return 1
  runtime_fetches="$(jq '[.transformations[] | select(.type == "CTFGetLocalResource/v1alpha1") | select(.spec.component | contains("graph/runtime"))] | length' "$GRAPH_DEMO_OUT/plan.json")"
  assert_eq "$runtime_fetches" "1" "shared runtime is fetched once" || return 1
}

test_graph_transfer_detects_changed_transitive_reference() {
  local tmp="$1" out
  _graph_build "$tmp" || return 1
  out="$(bash "$ROOT/scripts/graph.sh" tamper </dev/null 2>/dev/null)" || return 1
  assert_contains "$out" "digest mismatch" "tamper is rejected" || return 1
  assert_contains "$out" "runtime" "rejection names the runtime" || return 1
}

test_make_graph_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" graph 2>/dev/null)"
  assert_contains "$dry_run" "scripts/graph.sh" "dry-run includes graph.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "graph" "make help lists graph"
}

test_readme_documents_component_graphs() {
  local section check readme_yaml constructor_yaml

  doc_heading_exists "Component graphs" || \
    { echo "  README missing '## Component graphs' heading" >&2; return 1; }
  section="$(doc_section "Component graphs")"

  local checks=(
    "diamond"
    "first match wins"
    "digest mismatch"
    "make graph"
    "| flat |"
    "| recursive |"
    "#component-references)"
    "#resolvers)"
    "#transfer-and-transport)"
    "#signing-and-verification)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: every yaml block (minus # lines), in order, must match the three constructor files.
  readme_yaml="$(awk '/^```yaml/{f=1;next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -hv '^#' "$ROOT/components/graph/runtime.yaml" \
    "$ROOT/components/graph/apps.yaml" "$ROOT/components/graph/platform.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml blocks differ from components/graph/*.yaml" >&2
    return 1
  }
}

# ── GitHub access ────────────────────────────────────────────────────────────

# _github_env <tmp>
_github_env() {
  export GITHUB_DEMO_OUT="$1/github" \
         GITHUB_DEMO_CTF="$1/github-ctf" \
         GITHUB_DEMO_PORT="${GITHUB_TEST_PORT:-18452}" \
         OCM="$GITHUB_OCM"
}

# _github_build <tmp>: builds the component; output goes to a log so failures are visible.
_github_build() {
  _github_env "$1"
  bash "$ROOT/scripts/github.sh" build </dev/null >"$1/github-build.log" 2>&1 \
    || { tail -n 20 "$1/github-build.log" >&2; return 1; }
}

_github_ref() {
  echo "ctf::$GITHUB_DEMO_CTF//github.com/lioramilbaum/github-demo:$VERSION"
}

# _github_scenarios <tmp>: builds, then runs every scenario into <tmp>/scenarios.out.
_github_scenarios() {
  _github_build "$1" || return 1
  bash "$ROOT/scripts/github.sh" scenarios </dev/null >"$1/scenarios.out" 2>"$1/scenarios.err" \
    || { tail -n 20 "$1/scenarios.err" >&2; return 1; }
}

# _github_row <tmp> <scenario>: the tab-separated row for one scenario.
_github_row() {
  awk -F'\t' -v name="$2" '$1 == name' "$1/scenarios.out"
}

test_github_archive_is_deterministic() {
  local tmp="$1" sha="1111111111111111111111111111111111111111" top
  for name in a b; do
    python3 -I "$ROOT/scripts/github-api-server.py" --mode archive --sha "$sha" \
      --commits-dir "$ROOT/components/github/upstream" \
      --owner lioramilbaum --repo hello-world --out "$tmp/$name.tgz" || return 1
  done
  assert_eq "$(sha256 "$tmp/a.tgz")" "$(sha256 "$tmp/b.tgz")" "two archive builds match" || return 1
  top="$(tar -tzf "$tmp/a.tgz" | sed -n '1p')"
  assert_eq "$top" "lioramilbaum-hello-world-1111111/" "archive top directory" || return 1
}

test_github_access_pinned_at_build_time() {
  local tmp="$1" access
  _github_build "$tmp" || return 1
  access="$("$OCM" get cv "$(_github_ref)" -o json </dev/null | jq -r '.[0].component.resources[0].access | [.type, .ref, .commit] | join(" ")')"
  assert_eq "$access" "GitHub/v1 refs/heads/main 1111111111111111111111111111111111111111" "access is pinned to commit" || return 1
}

test_github_download_matches_digest() {
  local tmp="$1" stored
  _github_build "$tmp" || return 1
  bash "$ROOT/scripts/github.sh" download </dev/null >/dev/null 2>&1 || return 1
  stored="$("$OCM" get cv "$(_github_ref)" -o json </dev/null | jq -r '.[0].component.resources[0].digest.value')"
  assert_eq "$(sha256 "$tmp/github/archive.tgz")" "$stored" "downloaded archive matches stored digest" || return 1
}

test_github_ref_moved_keeps_pinned_commit() {
  local tmp="$1" row
  _github_scenarios "$tmp" || return 1
  row="$(_github_row "$tmp" branch-moved)"
  assert_contains "$row" "pinned-commit-kept" "branch move is ignored" || return 1
  assert_contains "$row" "1111111111111111111111111111111111111111" "fetched the pinned commit" || return 1
}

test_github_download_rejects_rewritten_archive() {
  local tmp="$1" row
  _github_scenarios "$tmp" || return 1
  row="$(_github_row "$tmp" archive-rewritten)"
  assert_contains "$row" "digest-mismatch" "rewritten archive is rejected" || return 1
  [[ ! -e "$tmp/github/scenario-archive.tgz" ]] || { echo "  rejected archive left behind" >&2; return 1; }
}

test_github_access_needs_api_at_consume_time() {
  local tmp="$1" row
  _github_scenarios "$tmp" || return 1
  row="$(_github_row "$tmp" api-down)"
  assert_contains "$row" "connection-refused" "download fails without the API" || return 1
}

test_github_transfer_copy_inlines_archive() {
  local tmp="$1" row
  _github_scenarios "$tmp" || return 1
  row="$(_github_row "$tmp" copied)"
  assert_contains "$row" "LocalBlob/v1" "copied archive is inlined" || return 1
}

test_github_server_port_in_use() {
  local tmp="$1" port="${GITHUB_TEST_PORT:-18452}" pid out
  _github_env "$tmp"
  # SO_REUSEADDR: a port left in TIME_WAIT by earlier tests must not stop the holder from binding.
  python3 -I -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $port)); s.listen(); time.sleep(60)" &
  pid=$!
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null || true" EXIT
  local i=0
  while ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    i=$((i+1)); [[ $i -lt 10 ]] || { echo "port holder never bound" >&2; return 1; }
    sleep 0.3
  done
  exec 3>&- 2>/dev/null || true

  if out="$(bash "$ROOT/scripts/github.sh" build 2>&1)"; then
    echo "  build should fail when the port is in use" >&2
    return 1
  fi
  assert_contains "$out" "port in use" "build reports the port in use"
}

test_github_online_is_opt_in() {
  local tmp="$1" out rc=0
  _github_env "$tmp"
  out="$(env -u GITHUB_DEMO_ONLINE bash "$ROOT/scripts/github.sh" online 2>&1)" || rc=$?
  assert_eq "$rc" "0" "online exits 0 without opt-in" || return 1
  assert_contains "$out" "skip:" "online reports skip" || return 1
  [[ ! -e "$GITHUB_DEMO_OUT/online-ctf" ]] || { echo "  online-ctf created without opt-in" >&2; return 1; }
}

test_github_online_release_asset() {
  local tmp="$1" out
  [[ "${OCM_ONLINE_TESTS:-0}" == 1 ]] || { echo "  skip: set OCM_ONLINE_TESTS=1"; return 77; }
  _github_env "$tmp"
  out="$(GITHUB_DEMO_ONLINE=1 bash "$ROOT/scripts/github.sh" online 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" "release asset: valid gzip" "online release asset is gzip"
}

test_make_github_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" github 2>/dev/null)"
  assert_contains "$dry_run" "scripts/github.sh" "dry-run includes github.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "github" "make help lists github"
}

test_readme_documents_github_access() {
  local section check readme_yaml constructor_yaml

  doc_heading_exists "GitHub access" || \
    { echo "  README missing '## GitHub access' heading" >&2; return 1; }
  section="$(doc_section "GitHub access")"

  local checks=(
    "GitHub/v1"
    "deprecated in favour of"
    "#git-repositories)"
    "#http-resources)"
    "Wget/v1"
    "api/v3"
    "/_codeload/"
    "tarball"
    "digest-mismatch"
    "connection-refused"
    "pinned-commit-kept"
    "LocalBlob/v1"
    "leaves the file"
    "GITHUB_DEMO_ONLINE=1"
    "S3/v1"
    "make github"
    "#credential-system)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block (minus # lines) must match the constructor.
  readme_yaml="$(awk '/^```yaml/{f=1;next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/github/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/github/component-constructor.yaml" >&2
    return 1
  }
}

# ── Signing normalisation ────────────────────────────────────────────────────

# _normalisation_env <tmp>
_normalisation_env() {
  export NORM_DEMO_OUT="$1/normalisation" OCM="$NORM_OCM"
}

# _normalisation_row <compare-output> <variant> <column>: one field of one compare row.
_normalisation_row() {
  awk -F'\t' -v name="$2" -v col="$3" '$1 == name { print $col }' <<<"$1"
}

test_normalisation_matches_ocm_digest() {
  local tmp="$1" out
  _normalisation_env "$tmp"
  _build
  out="$(bash "$ROOT/scripts/normalisation.sh" normalise </dev/null 2>/dev/null)" || return 1
  assert_eq "$(sha256 "$NORM_DEMO_OUT/application.normalised.json")" \
    "$(awk -F'\t' '$1 == "ocm" { print $2 }' <<<"$out")" "normalised file hashes to the OCM digest" || return 1
}

test_normalisation_excludes_unsigned_fields() {
  local tmp="$1" content
  _normalisation_env "$tmp"
  _build
  bash "$ROOT/scripts/normalisation.sh" normalise </dev/null >/dev/null 2>&1 || return 1
  content="$(< "$NORM_DEMO_OUT/application.normalised.json")"
  assert_not_contains "$content" '"meta"' || return 1
  assert_not_contains "$content" '"signatures"' || return 1
  assert_not_contains "$content" '"repositoryContexts"' || return 1
  assert_not_contains "$content" '"access"' || return 1
  assert_not_contains "$content" '"srcRefs"' || return 1
  assert_not_contains "$content" 'application.lioramilbaum.github.com/tier' || return 1
  assert_contains "$content" '"provider":{"name":' "provider is normalised to a map" || return 1
}

test_normalisation_label_vs_blob_digests() {
  local tmp="$1" out
  _normalisation_env "$tmp"
  out="$(bash "$ROOT/scripts/normalisation.sh" compare </dev/null 2>/dev/null)" || return 1
  assert_eq "$(_normalisation_row "$out" unsigned-label 4)$(_normalisation_row "$out" unsigned-label 5)" "nono" \
    "unsigned label changes neither digest" || return 1
  assert_eq "$(_normalisation_row "$out" signed-label 4)$(_normalisation_row "$out" signed-label 5)" "noyes" \
    "signed label changes only the component digest" || return 1
  assert_eq "$(_normalisation_row "$out" blob 4)$(_normalisation_row "$out" blob 5)" "yesyes" \
    "blob change changes both digests" || return 1
}

test_normalisation_reimplementation_matches_each_variant() {
  local tmp="$1" out rows bad
  _normalisation_env "$tmp"
  out="$(bash "$ROOT/scripts/normalisation.sh" compare </dev/null 2>/dev/null)" || return 1
  rows="$(awk -F'\t' 'NR > 1' <<<"$out" | wc -l | tr -d ' ')"
  assert_eq "$rows" "4" "compare has four variant rows" || return 1
  bad="$(awk -F'\t' 'NR > 1 && $6 != "yes"' <<<"$out" | wc -l | tr -d ' ')"
  assert_eq "$bad" "0" "every variant matches the jq reimplementation" || return 1
}

test_normalisation_rejects_legacy_v1() {
  local tmp="$1" out
  _normalisation_env "$tmp"
  out="$(bash "$ROOT/scripts/normalisation.sh" algorithms </dev/null 2>/dev/null)" || return 1
  assert_contains "$out" "jsonNormalisation/v1" || return 1
  assert_contains "$out" "unknown normalisation" "legacy algorithm is rejected" || return 1
}

test_make_normalisation_target() {
  local dry_run help_out
  dry_run="$(make -s --dry-run -C "$ROOT" normalisation 2>/dev/null)"
  assert_contains "$dry_run" "scripts/build.sh" "dry-run includes build.sh" || return 1
  assert_contains "$dry_run" "scripts/normalisation.sh" "dry-run includes normalisation.sh" || return 1
  help_out="$(make -s -C "$ROOT" help 2>/dev/null)"
  assert_contains "$help_out" "normalisation" "make help lists normalisation"
}

test_readme_documents_signing_normalisation() {
  local section check readme_yaml constructor_yaml

  doc_heading_exists "Signing normalisation" || \
    { echo "  README missing '## Signing normalisation' heading" >&2; return 1; }
  section="$(doc_section "Signing normalisation")"

  local checks=(
    "jsonNormalisation/v4alpha1"
    "unknown normalisation algorithm"
    "jsonNormalisation/v1"
    "make normalisation"
    "components/normalisation/jsonNormalisation-v4alpha1.jq"
    "ocm sign cv --dry-run"
    "jq-matches-ocm"
    "| \`unsigned-label\` |"
    "| \`signed-label\` |"
    "| \`blob\` |"
    "#signing-and-verification)"
  )
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block (minus # lines) must match the constructor.
  readme_yaml="$(awk '/^```yaml/{f=1;next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/normalisation/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/normalisation/component-constructor.yaml" >&2
    return 1
  }
}

# ── S3 resources ─────────────────────────────────────────────────────────────

# _s3_env <tmp>
_s3_env() {
  export S3_NAME="ocm-demo-s3-test" \
         S3_PORT="${S3_TEST_PORT:-19001}" \
         S3_DEMO_CTF="$1/s3-ctf" \
         S3_DEMO_OUT="$1/s3" \
         OCM="$S3_OCM"
}

_s3_docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# _s3_start <tmp>: start and seed the test server; the test subshell removes it on exit.
_s3_start() {
  _s3_env "$1"
  trap 'bash "$ROOT/scripts/s3.sh" stop >/dev/null 2>&1 || true' EXIT
  bash "$ROOT/scripts/s3.sh" start >/dev/null
  bash "$ROOT/scripts/s3.sh" seed >/dev/null
}

# _s3_build: build the demo component against the running test server.
_s3_build() {
  bash "$ROOT/scripts/s3.sh" build >/dev/null 2>&1
}

# _s3_scenarios <tmp>: start, build and sign the demo, then run every scenario into scenarios.tsv.
_s3_scenarios() {
  _s3_start "$1"
  _s3_build
  bash "$ROOT/scripts/s3.sh" sign >/dev/null
  bash "$ROOT/scripts/s3.sh" scenarios > "$S3_DEMO_OUT/scenarios.tsv"
}

# _s3_row <scenario> <resource>
_s3_row() {
  awk -F'\t' -v s="$1" -v r="$2" '$1 == s && $2 == r { print $3 }' "$S3_DEMO_OUT/scenarios.tsv"
}

# _s3_access <resource> <jq-filter>: reads the built descriptor.
_s3_access() {
  "$OCM" get cv "ctf::${S3_DEMO_CTF}//github.com/lioramilbaum/s3-demo:${VERSION}" -o json </dev/null \
    | jq -r --arg n "$1" ".[0].component.resources[] | select(.name == \$n) | $2"
}

# _s3_get <path>: signed GET against the test server, bypassing OCM.
_s3_get() {
  curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "ocm-demo:ocm-demo-secret" \
    -H "x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    "http://127.0.0.1:${S3_PORT}$1"
}

test_s3_image_pinned_by_digest() {
  local image
  image="$(grep '^S3_IMAGE=' "$ROOT/scripts/s3.sh")"
  assert_contains "$image" "@sha256:"
}

test_s3_docker_skip_without_docker() {
  _s3_env "$1"
  local stub="$1/stub-bin" out rc=0
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/docker"
  chmod +x "$stub/docker"
  out="$(PATH="$stub:$PATH" bash "$ROOT/scripts/s3.sh" start 2>&1)" || rc=$?
  assert_eq "$rc" "0" "exit status without docker" || return 1
  assert_contains "$out" "skip:"
}

test_s3_seed_uploads_object() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  assert_eq "$(_s3_get /ocm-demo/releases/notes.txt)" "$(cat "$ROOT/components/s3/upstream/release-notes.txt")"
}

test_s3_access_records_endpoint() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  assert_eq "$(_s3_access notes '.access.endpoint')" "http://127.0.0.1:${S3_PORT}"
}

test_s3_access_v1_uses_bucket_key_fields() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  assert_eq "$(_s3_access notes-v1 '.access.bucket')" "ocm-demo" || return 1
  assert_eq "$(_s3_access notes-v1 '.access.key')" "releases/notes.txt"
}

test_s3_access_v2_uses_bucket_name_fields() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  assert_eq "$(_s3_access notes '.access.bucketName')" "ocm-demo"
}

test_s3_unversioned_build_warns_no_pin() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  local log
  log="$(bash "$ROOT/scripts/s3.sh" build 2>&1)"
  assert_contains "$log" "carries no version"
}

test_s3_versioned_bucket_pins_version() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  local version
  version="$(cat "$S3_DEMO_OUT/seed-version")"
  [[ -n "$version" ]] || { echo "  seed-version is empty" >&2; return 1; }
  assert_eq "$(_s3_access notes-pinned '.access.version')" "$version"
}

test_s3_input_becomes_local_blob() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  assert_eq "$(_s3_access notes-input '.access.type')" "LocalBlob/v1"
}

test_s3_download_v1_and_v2() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  _s3_build
  bash "$ROOT/scripts/s3.sh" sign >/dev/null
  local out
  out="$(bash "$ROOT/scripts/s3.sh" download)"
  assert_contains "$out" $'download\tnotes-v1\tok' || return 1
  assert_contains "$out" $'download\tnotes\tok'
}

test_s3_download_rejects_overwritten_object() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row overwritten notes)" "digest-mismatch" || return 1
}

test_s3_pinned_version_survives_overwrite() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row overwritten-versioned notes-pinned)" "ok"
}

test_s3_input_works_offline() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row server-down notes-input)" "ok"
}

test_s3_credentials_required() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row no-credentials notes)" "credentials-missing"
}

test_s3_glob_star_matches() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row glob-star notes)" "ok"
}

test_s3_doublestar_not_matched() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row glob-doublestar notes)" "ok"
}

test_s3_transfer_copies_v2_only() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_scenarios "$1"
  assert_eq "$(_s3_row copied-v2 notes)" "LocalBlob/v1" || return 1
  assert_eq "$(_s3_row copied-v1 notes-v1)" "S3/v1"
}

test_s3_stop_removes_container() {
  _s3_docker_available || { echo "  skip: Docker not available"; return 77; }
  _s3_start "$1"
  bash "$ROOT/scripts/s3.sh" stop >/dev/null
  if docker ps -a --format '{{.Names}}' | grep -qx "$S3_NAME"; then
    echo "  container $S3_NAME still exists after stop" >&2
    return 1
  fi
}

test_make_s3_target() {
  local dry help
  dry="$(make -C "$ROOT" -n s3 OCM="$S3_OCM")"
  assert_contains "$dry" "scripts/s3.sh" || return 1
  help="$(make -C "$ROOT" help)"
  assert_contains "$help" "  s3 "
}

test_readme_documents_s3_resources() {
  local section readme_yaml constructor_yaml
  doc_heading_exists "S3 resources" || {
    echo "  README missing '## S3 resources' heading" >&2
    return 1
  }
  section="$(doc_section "S3 resources")"

  local checks=(
    "rustfs"
    "S3/v1"
    "S3/v2"
    "AWS_SHARED_CREDENTIALS_FILE"
    "carries no version"
    "x-amz-version-id"
    "digest-mismatch"
    "credentials-missing"
    "connection-refused"
    "LocalBlob/v1"
    "--copy-resources"
    "Input vs access"
    "make s3"
    "bash scripts/s3.sh stop"
    "#credential-system)"
  )
  local check
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block (minus # lines) must match the constructor.
  readme_yaml="$(awk '/^```yaml/{f=1;next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/s3/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/s3/component-constructor.yaml" >&2
    return 1
  }
}

# ── Resources without access (None) ─────────────────────────────────────────

# _none_env <tmp>
_none_env() {
  export NONE_DEMO_CTF="$1/none-access-ctf" \
         NONE_DEMO_OUT="$1/none-access" \
         OCM="$NONE_OCM"
}

# _none_build <tmp>: build the demo component.
_none_build() {
  _none_env "$1"
  bash "$ROOT/scripts/none-access.sh" build >/dev/null 2>&1
}

# _none_signed <tmp>: build and sign the demo component.
_none_signed() {
  _none_build "$1"
  bash "$ROOT/scripts/none-access.sh" sign >/dev/null 2>&1
}

# _none_variants <tmp>: run the variants table into variants.tsv.
_none_variants() {
  _none_env "$1"
  mkdir -p "$NONE_DEMO_OUT"
  bash "$ROOT/scripts/none-access.sh" variants > "$NONE_DEMO_OUT/variants.tsv" 2>/dev/null
}

# _none_row <variant> <column>: columns are 1 variant, 2 access-type, 3 has-digest,
# 4 component-digest, 5 same-as-base, 6 sign-warning.
_none_row() {
  awk -F'\t' -v v="$1" -v c="$2" '$1 == v { print $c }' "$NONE_DEMO_OUT/variants.tsv"
}

test_none_access_provenance_json_matches_label() {
  local label actual
  label="$(grep -F 'value: "' "$ROOT/components/none-access/component-constructor.yaml" | sed 's/.*value: "\([0-9a-f]*\)".*/\1/')"
  actual="$(sha256 "$ROOT/components/none-access/provenance.json")"
  assert_eq "$actual" "$label"
}

test_none_access_resource_has_no_digest_in_descriptor() {
  _none_build "$1"
  local digest
  digest="$("$OCM" get cv "ctf::${NONE_DEMO_CTF}//github.com/lioramilbaum/none-access-demo:${VERSION}" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name == "provenance") | .digest // "none"')"
  assert_eq "$digest" "none"
}

test_none_access_build_warns_no_digest_processor() {
  _none_build "$1"
  assert_contains "$(cat "$1/none-access/build.log")" "digest processor"
}

test_none_access_control_resource_downloads() {
  _none_build "$1"
  local out
  out="$(bash "$ROOT/scripts/none-access.sh" download)"
  assert_contains "$out" $'release-notes\tok'
}

test_none_access_download_fails_gracefully() {
  _none_build "$1"
  local out
  out="$(bash "$ROOT/scripts/none-access.sh" download)"
  assert_contains "$out" $'provenance\tno-access' || return 1
}

test_none_access_sign_and_verify() {
  _none_signed "$1"
  bash "$ROOT/scripts/none-access.sh" verify >/dev/null
}

test_none_access_digest_not_signed() {
  _none_variants "$1"
  assert_eq "$(_none_row digest-a 5)" "yes" "digest-a same as base" || return 1
  assert_eq "$(_none_row digest-b 5)" "yes" "digest-b same as base"
}

test_none_access_digest_triggers_warning() {
  _none_variants "$1"
  assert_contains "$(_none_row digest-a 6)" "not allowed"
}

test_none_access_lowercase_warns_missing_digest() {
  _none_variants "$1"
  local warning
  warning="$(_none_row lowercase 6)"
  assert_contains "$warning" "missing digest" || return 1
  assert_not_contains "$warning" "none"
}

test_none_access_versioned_type_is_not_none() {
  _none_variants "$1"
  assert_eq "$(_none_row versioned-type 5)" "no"
}

test_none_access_identity_is_signed() {
  _none_variants "$1"
  assert_eq "$(_none_row renamed 5)" "no"
}

test_none_access_label_is_signed() {
  _none_variants "$1"
  assert_eq "$(_none_row label-changed 5)" "no"
}

test_none_access_audit_passes() {
  _none_signed "$1"
  local out
  out="$(bash "$ROOT/scripts/none-access.sh" audit)"
  assert_contains "$out" "passed"
}

test_none_access_audit_detects_tamper() {
  _none_signed "$1"
  local tampered="$1/tampered-provenance.json" err rc=0
  cp "$ROOT/components/none-access/provenance.json" "$tampered"
  printf ' ' >> "$tampered"
  err="$(NONE_PROVENANCE_FILE="$tampered" bash "$ROOT/scripts/none-access.sh" audit 2>&1)" || rc=$?
  [[ $rc -ne 0 ]] || { echo "  audit accepted tampered provenance" >&2; return 1; }
  assert_contains "$err" "audit failed"
}

test_none_access_transfer_keeps_none() {
  _none_signed "$1"
  local out
  out="$(bash "$ROOT/scripts/none-access.sh" transfer)"
  assert_contains "$out" $'plain\tNone\tok'
}

test_none_access_copy_resources_keeps_none() {
  _none_signed "$1"
  local out
  out="$(bash "$ROOT/scripts/none-access.sh" transfer)"
  assert_contains "$out" $'copy-resources\tNone\tok'
}

test_make_none_access_target() {
  local dry help
  dry="$(make -C "$ROOT" -n none-access OCM="$NONE_OCM")"
  assert_contains "$dry" "scripts/none-access.sh" || return 1
  help="$(make -C "$ROOT" help)"
  assert_contains "$help" "  none-access "
}

test_readme_documents_none_access() {
  local section readme_yaml constructor_yaml
  doc_heading_exists "Resources without access (None)" || {
    echo "  README missing '## Resources without access (None)' heading" >&2
    return 1
  }
  section="$(doc_section "Resources without access")"

  local checks=(
    "None/v1"
    "not signed"
    "#signing-normalisation)"
    "jsonNormalisation/v4alpha1"
    "not allowed"
    "missing digest"
    "signing: true"
    "bash scripts/none-access.sh audit"
    "audit failed"
    "make none-access"
  )
  local check
  for check in "${checks[@]}"; do
    assert_contains "$section" "$check" "README section contains: $check" || return 1
  done

  # Drift guard: the first yaml block (minus # lines) must match the constructor.
  readme_yaml="$(awk '/^```yaml/{f=1;next} /^```/{f=0} f' <<<"$section" | grep -v '^#')"
  constructor_yaml="$(grep -v '^#' "$ROOT/components/none-access/component-constructor.yaml")"
  [[ "$readme_yaml" == "$constructor_yaml" ]] || {
    echo "  README yaml block differs from components/none-access/component-constructor.yaml" >&2
    return 1
  }
}

test_readme_intro_lists_demos() {
  local intro
  intro="$(awk '/^# /{f=1; next} /^## Quick start$/{f=0} f' "$ROOT/README.md")"
  [[ -n "$intro" ]] || { echo "  README has no text between the H1 and '## Quick start'" >&2; return 1; }
  assert_contains "$intro" "product component" || return 1
  assert_contains "$intro" "version selection" || return 1
}

test_readme_is_docs_index() {
  local line_count doc name heading
  [[ -d "$ROOT/docs" ]] || { echo "  docs/ directory is missing" >&2; return 1; }
  line_count="$(wc -l < "$ROOT/README.md" | tr -d ' ')"
  [[ "$line_count" -le 120 ]] || { echo "  README.md has $line_count lines, expected at most 120" >&2; return 1; }
  for doc in "$ROOT"/docs/*.md; do
    name="$(basename "$doc")"
    grep -qF "](docs/$name" "$ROOT/README.md" || { echo "  README.md does not link docs/$name" >&2; return 1; }
  done
  # The index keeps only its own "## " headings; every other section must live in docs/.
  while IFS= read -r heading; do
    case "$heading" in
      "## Quick start"|"## Documentation") ;;
      *) echo "  README.md still contains '$heading' (it belongs in docs/)" >&2; return 1 ;;
    esac
  done < <(grep -E '^## ' "$ROOT/README.md")
}

test_docs_links_resolve() {
  local file target path anchor dest failed=0
  while IFS=$'\t' read -r file target; do
    case "$target" in
      http://*|https://*|mailto:*) continue ;;
    esac
    path="${target%%#*}"
    anchor=""
    if [[ "$target" == *"#"* ]]; then anchor="${target#*#}"; fi
    if [[ -z "$path" ]]; then dest="$file"; else dest="$(dirname "$file")/$path"; fi
    if [[ ! -e "$dest" ]]; then
      echo "  ${file#"$ROOT"/} links to missing file: $target" >&2
      failed=1
    elif [[ -n "$anchor" ]] && ! grep -qxF -- "$anchor" <<< "$(_heading_slugs "$dest")"; then
      echo "  ${file#"$ROOT"/} links to missing anchor: $target" >&2
      failed=1
    fi
  done < <(awk '/^(```|~~~)/{ if(!c){c=1; m=substr($0,1,3)} else if(substr($0,1,3)==m){c=0}; next } !c { line=$0; while (match(line, /!?\[[^]]*\]\([^)]*\)/)) { tok=substr(line, RSTART, RLENGTH); if (substr(tok,1,1) != "!") { i=index(tok,"]("); print FILENAME "\t" substr(tok, i+2, length(tok)-i-2) }; line=substr(line, RSTART+RLENGTH) } }' "${DOC_FILES[@]}" "$ROOT/CONTRIBUTING.md")
  return "$failed"
}

test_license_is_apache_2() {
  local tmp="$1"
  [[ -f "$ROOT/LICENSE" ]] || { echo "  LICENSE is missing" >&2; return 1; }
  # Restore the placeholder so the hash matches the canonical Apache 2.0 text.
  sed 's/^   Copyright [0-9]\{4\} Liora Milbaum$/   Copyright [yyyy] [name of copyright owner]/' "$ROOT/LICENSE" > "$tmp/LICENSE"
  assert_eq "$(sha256 "$tmp/LICENSE")" "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30" "LICENSE is Apache 2.0 text" || return 1
  grep -q '^   Copyright [0-9]\{4\} Liora Milbaum$' "$ROOT/LICENSE" || { echo "  LICENSE copyright line is not filled in" >&2; return 1; }
}

test_contributing_guide_covers_workflow() {
  local guide="$ROOT/CONTRIBUTING.md" text needle
  [[ -f "$guide" ]] || { echo "  CONTRIBUTING.md is missing" >&2; return 1; }
  [[ "$(head -n 1 "$guide")" == "# Contributing" ]] || { echo "  CONTRIBUTING.md does not start with '# Contributing'" >&2; return 1; }
  text="$(cat "$guide")"
  for needle in ".devcontainer" "make lint" "make test" "feat/<name>" "lioramilbaum/application" "--draft" "Conventional Commits" "Squash" "Co-Authored-By:" "](LICENSE)"; do
    assert_contains "$text" "$needle" "CONTRIBUTING.md" || return 1
  done
}

test_flux_artifact_is_reproducible() {
  local tmp="$1"
  cp -r "$ROOT/components/hello-world" "$tmp/src-a"
  cp -r "$ROOT/components/hello-world" "$tmp/src-b"
  # Run each copy's own script so it resolves manifests.yaml from the copy (it reads from its own directory).
  python3 -I "$tmp/src-a/flux-artifact.py" "$tmp/src-a" || { echo "  first run failed" >&2; return 1; }
  python3 -I "$tmp/src-b/flux-artifact.py" "$tmp/src-b" || { echo "  second run failed" >&2; return 1; }
  cmp "$tmp/src-a/hello-world-kustomize.oci.tar" "$tmp/src-b/hello-world-kustomize.oci.tar" \
    || { echo "  flux artifact is not reproducible" >&2; return 1; }
}

test_flux_artifact_resource_is_flux_oci_layout() {
  local tmp="$1"
  _build || return 1
  local cv; cv="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)" || return 1
  echo "$cv" | jq -e '.[0].component.resources[] | select(.name=="hello-world-kustomize") | .type == "blob"' > /dev/null || return 1
  # Fetch the artifact from the CTF as an unextracted blob and verify its tar structure
  "$OCM" download resource "$(cv_ref "$ROOT_COMPONENT")" --identity name=hello-world-kustomize \
    --output "$tmp/flux.oci.tar" --extraction-policy disable >/dev/null || return 1
  mkdir -p "$tmp/layout"
  tar -xf "$tmp/flux.oci.tar" -C "$tmp/layout" || return 1
  # ocm writes the layout entries with mode 0 when it repacks them from the CTF
  chmod -R u+rw "$tmp/layout"
  [[ -f "$tmp/layout/oci-layout" ]] || { echo "  missing oci-layout" >&2; return 1; }
  jq -e '.manifests[0].mediaType == "application/vnd.oci.image.manifest.v1+json"' "$tmp/layout/index.json" > /dev/null || return 1
  local manifest_digest; manifest_digest="$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' "$tmp/layout/index.json")" || return 1
  jq -e '.config.mediaType == "application/vnd.cncf.flux.config.v1+json"' "$tmp/layout/blobs/sha256/$manifest_digest" > /dev/null || return 1
  jq -e '.layers[0].mediaType == "application/vnd.cncf.flux.content.v1.tar+gzip"' "$tmp/layout/blobs/sha256/$manifest_digest" > /dev/null || return 1
}

test_flux_artifact_is_not_committed() {
  local tmp="$1"
  # Skip if not inside a git checkout
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 77
  # Must not be tracked
  if git -C "$ROOT" ls-files --error-unmatch "components/hello-world/hello-world-kustomize.oci.tar" 2>/dev/null; then
    echo "  hello-world-kustomize.oci.tar is still tracked by git" >&2
    return 1
  fi
  # Must be ignored
  git -C "$ROOT" check-ignore -q "components/hello-world/hello-world-kustomize.oci.tar" \
    || { echo "  hello-world-kustomize.oci.tar is not in .gitignore" >&2; return 1; }
}

test_build_generates_flux_artifact() {
  local tmp="$1"
  # Same repo copy as _build_variant: constructor, scripts and components
  local repo="$tmp/variant-repo"
  mkdir -p "$repo"
  cp -R "$ROOT/component-constructor.yaml" "$ROOT/scripts" "$ROOT/components" "$repo/"
  # Remove the tar so build.sh must generate it
  rm -f "$repo/components/hello-world/hello-world-kustomize.oci.tar"
  # Append a build marker so we can verify the generated content matches
  printf '\n# flux-artifact build marker\n' >> "$repo/components/hello-world/manifests.yaml"
  SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567 \
    BUILD_DIR="$tmp/variant-build" CTF="$tmp/variant-ctf" \
    bash "$repo/scripts/build.sh" >"$tmp/build.log" 2>&1 \
    || { echo "  build.sh failed" >&2; tail -5 "$tmp/build.log" >&2; return 1; }
  local gen="$repo/components/hello-world/hello-world-kustomize.oci.tar"
  [[ -f "$gen" ]] || { echo "  build.sh did not generate the tar" >&2; return 1; }
  # Unpack the OCI layout, then the Flux content layer, and find the marker in manifests.yaml
  mkdir -p "$tmp/gen/layout" "$tmp/gen/content"
  tar -xf "$gen" -C "$tmp/gen/layout" || return 1
  local manifest_digest layer_digest
  manifest_digest="$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' "$tmp/gen/layout/index.json")" || return 1
  layer_digest="$(jq -r '.layers[0].digest | ltrimstr("sha256:")' "$tmp/gen/layout/blobs/sha256/$manifest_digest")" || return 1
  tar -xzf "$tmp/gen/layout/blobs/sha256/$layer_digest" -C "$tmp/gen/content" || return 1
  grep -q 'flux-artifact build marker' "$tmp/gen/content/manifests.yaml" \
    || { echo "  generated tar does not contain modified manifests.yaml" >&2; return 1; }
}

test_rgd_mirrors_localization_and_config() {
  local rgd="$ROOT/components/hello-world/rgd.yaml"
  grep -q "kind: ResourceGraphDefinition" "$rgd" || return 1
  grep -q "hello-world-kustomize" "$rgd" || return 1
  grep -q "hello-world-image" "$rgd" || return 1
  grep -q "json.marshal" "$rgd" || return 1
  grep -q "kind: OCIRepository" "$rgd" || return 1
  grep -q "kind: Kustomization" "$rgd" || return 1
  # Every placeholder in manifests.yaml must appear in the rgd
  local placeholder
  while IFS= read -r placeholder; do
    grep -q "$placeholder" "$rgd" || { echo "  RGD missing placeholder: $placeholder" >&2; return 1; }
  done < <(grep -oE 'HELLO_WORLD_[A-Z_]+' "$ROOT/components/hello-world/manifests.yaml" | sort -u)
  # instance.yaml replicas and html must equal config.json values
  local cfg_replicas; cfg_replicas="$(jq -r '[.configurations[] | select(.name=="replicas")] | .[0].value' "$ROOT/components/hello-world/config.json")" || return 1
  local inst_replicas; inst_replicas="$(grep 'replicas:' "$ROOT/k8s/controller/instance.yaml" | awk '{print $2}')" || return 1
  [[ "$cfg_replicas" == "$inst_replicas" ]] || { echo "  instance.yaml replicas does not match config.json" >&2; return 1; }
  local cfg_html; cfg_html="$(jq -r '[.configurations[] | select(.name=="index-html")] | .[0].value' "$ROOT/components/hello-world/config.json")" || return 1
  local inst_html; inst_html="$(python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print(d['spec']['html'],end='')" < "$ROOT/k8s/controller/instance.yaml")" || return 1
  [[ "$cfg_html" == "$inst_html" ]] || { echo "  instance.yaml html does not match config.json" >&2; return 1; }
}

test_controller_bootstrap_wires_published_component() {
  local bootstrap="$ROOT/k8s/controller/bootstrap.yaml"
  grep -q "baseUrl: ghcr.io/lioramilbaum/ocm" "$bootstrap" || return 1
  grep -q "component: $ROOT_COMPONENT" "$bootstrap" || return 1
  grep -q "kind: NamespacedDeployer" "$bootstrap" || return 1
  grep -q "serviceAccountName: hello-world-deployer" "$bootstrap" || return 1
  grep -q "resourcegraphdefinitions" "$bootstrap" || return 1
  grep -q "name: hello-world-rgd" "$bootstrap" || return 1
  # Every OCM resource referenced by byReference in bootstrap must exist in the built descriptor
  _build || return 1
  local cv_json rname
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)" || return 1
  while IFS= read -r rname; do
    jq -e --arg n "$rname" '.[0].component.resources[] | select(.name==$n)' <<< "$cv_json" > /dev/null \
      || { echo "  resource $rname not found in descriptor" >&2; return 1; }
  done < <(awk '/byReference:/{f=1; next} f && /name: /{print $NF; f=0}' "$bootstrap")
}

test_controller_sh_installs_stack() {
  local tmp="$1"
  export STUB_LOG_DIR="$tmp"
  _stub_kind "$tmp" > /dev/null
  _stub_controller_tools "$tmp"
  PATH="$tmp:$PATH" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    bash "$ROOT/scripts/controller.sh" install || return 1
  local ocm_ver; ocm_ver=$(sed -n 's/^OCM_CONTROLLER_CHART_VERSION="\([^"]*\)"/\1/p' "$ROOT/scripts/controller.sh")
  local kro_ver; kro_ver=$(sed -n 's/^KRO_CHART_VERSION="\([^"]*\)"/\1/p' "$ROOT/scripts/controller.sh")
  local flux_ver; flux_ver=$(sed -n 's/^FLUX_VERSION="\([^"]*\)"/\1/p' "$ROOT/scripts/controller.sh")
  grep -q "upgrade --install ocm-k8s-toolkit oci://ghcr.io/open-component-model/kubernetes/controller/chart --version $ocm_ver --namespace ocm-k8s-toolkit-system" "$tmp/helm.log" || return 1
  grep -q "upgrade --install kro oci://registry.k8s.io/kro/charts/kro --version $kro_ver --namespace kro-system" "$tmp/helm.log" || return 1
  grep -q "install --version $flux_ver" "$tmp/flux.log" || return 1
}

test_controller_sh_applies_bootstrap_and_checks_app() {
  local tmp="$1"
  export STUB_LOG_DIR="$tmp"
  # Make kubectl wait/rollout succeed silently, exec print Hello
  _stub_controller_tools "$tmp"
  PATH="$tmp:$PATH" KUBECTL="$tmp/kubectl" \
    OCM_CONTROLLER_REPO="ghcr.io/example/ocm" \
    bash "$ROOT/scripts/controller.sh" apply || return 1
  grep -q "baseUrl: ghcr.io/example/ocm" "$tmp/kubectl-stdin.log" || return 1
  grep -q "kind: NamespacedDeployer" "$tmp/kubectl-stdin.log" || return 1
  grep -q "wait --for=condition=Ready" "$tmp/kubectl.log" || return 1
  grep -q "namespaceddeployer/hello-world" "$tmp/kubectl.log" || return 1
}

test_controller_sh_cluster_lifecycle() {
  local tmp; tmp="$(mktemp -d)"
  export STUB_LOG_DIR="$tmp"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  # cluster.sh runs inside `run` and uses the stubbed kind and docker
  PATH="$stub_dir:$PATH" KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    bash "$ROOT/scripts/controller.sh" run > /dev/null || return 1
  assert_contains "$(cat "$tmp/kind.log")" "create cluster --name ocm-controller" || return 1
  assert_contains "$(cat "$tmp/helm.log")" "upgrade --install kro" || return 1
  rm -rf "$tmp"
}

test_make_controller_target() {
  local out
  out="$(make -n -C "$ROOT" controller 2>/dev/null)"
  assert_contains "$out" "scripts/controller.sh" || return 1
  out="$(make -C "$ROOT" help)"
  assert_contains "$out" "  controller " || return 1
}

test_docs_document_controller_stack() {
  local doc="$ROOT/docs/controller.md"
  grep -q "https://ocm.software/docs/getting-started/set-up-controller-environments/" "$doc" || return 1
  grep -q "https://ocm.software/docs/getting-started/deploy-helm-charts/" "$doc" || return 1
  grep -q "flux install" "$doc" || return 1
  grep -q "ghcr.io/open-component-model/kubernetes/controller/chart" "$doc" || return 1
  grep -q "registry.k8s.io/kro/charts/kro" "$doc" || return 1
  grep -q "make controller" "$doc" || return 1
  grep -q "KEEP_CLUSTER" "$doc" || return 1
  grep -q "OCM_CONTROLLER_REPO" "$doc" || return 1
}

test_controller_sh_run_deletes_created_cluster() {
  local tmp="$1"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  PATH="$stub_dir:$PATH" KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" run > /dev/null 2>&1 || true
  # kind created the cluster
  grep -q "create cluster.*--name ocm-controller" "$tmp/kind.log" || { echo "  kind create not called" >&2; return 1; }
  # kubeconfig written inside tmp (not the e2e kubeconfig or ~/.kube/config)
  grep -qF "create cluster --name ocm-controller --kubeconfig $tmp/" "$tmp/kind.log" \
    || { echo "  kubeconfig not isolated to tmp" >&2; return 1; }
  # kind deleted the cluster on exit
  grep -q "delete cluster.*--name ocm-controller" "$tmp/kind.log" || { echo "  kind delete not called" >&2; return 1; }
}

test_controller_sh_run_keep_cluster() {
  local tmp="$1"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  KEEP_CLUSTER=1 PATH="$stub_dir:$PATH" KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" run > /dev/null 2>&1 || true
  grep -q "create cluster.*--name ocm-controller" "$tmp/kind.log" || { echo "  kind create not called" >&2; return 1; }
  ! grep -q "delete cluster" "$tmp/kind.log" \
    || { echo "  kind delete was called despite KEEP_CLUSTER=1" >&2; return 1; }
}

test_controller_sh_run_reuses_existing_cluster() {
  local tmp="$1"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  # Pre-seed the kind stub's cluster list (a file read by `kind get clusters`)
  echo "ocm-controller" > "$tmp/kind-clusters"
  PATH="$stub_dir:$PATH" KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" run > /dev/null 2>&1 || true
  # Should export kubeconfig, not create
  grep -qE "export kubeconfig.*--name ocm-controller|get-kubeconfig.*ocm-controller" "$tmp/kind.log" \
    || { echo "  kind get/export kubeconfig not called" >&2; return 1; }
  ! grep -q "create cluster" "$tmp/kind.log" \
    || { echo "  kind create was called on existing cluster" >&2; return 1; }
}

test_controller_sh_down_deletes_cluster() {
  local tmp="$1"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" down > /dev/null 2>&1 || true
  grep -q "delete cluster.*--name ocm-controller" "$tmp/kind.log" || { echo "  kind delete not called" >&2; return 1; }
}

test_controller_sh_rejects_unknown_subcommand() {
  local tmp="$1"
  local stub_dir; stub_dir="$(_stub_kind "$tmp")"
  _stub_controller_tools "$tmp"
  local out
  if out=$(PATH="$stub_dir:$PATH" KIND="$stub_dir/kind" HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" bogus 2>&1); then
    echo "  expected non-zero exit for unknown subcommand" >&2; return 1
  fi
  echo "$out" | grep -qi "usage\|unknown\|invalid" || { echo "  no usage message for unknown subcommand, got: $out" >&2; return 1; }
}

test_controller_sh_apply_sets_target_architecture() {
  local tmp="$1"
  _stub_kind "$tmp" > /dev/null
  _stub_controller_tools "$tmp"
  TARGET_ARCH=arm64 HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    KUBECONFIG="$tmp/kubeconfig" STUB_LOG_DIR="$tmp" \
    bash "$ROOT/scripts/controller.sh" apply > /dev/null 2>&1 || true
  grep -q "architecture: arm64" "$tmp/kubectl-stdin.log" 2>/dev/null \
    || { echo "  arm64 architecture not applied in kubectl-stdin.log" >&2; return 1; }
  ! grep -q "architecture: amd64" "$tmp/kubectl-stdin.log" 2>/dev/null \
    || { echo "  amd64 still present after TARGET_ARCH=arm64" >&2; return 1; }
}

test_controller_sh_check_fails_without_answer() {
  local tmp="$1"
  _stub_kind "$tmp" > /dev/null
  _stub_controller_tools "$tmp"
  # Default check should succeed
  HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    KUBECONFIG="$tmp/kubeconfig" STUB_LOG_DIR="$tmp" \
    bash "$ROOT/scripts/controller.sh" check > /dev/null 2>&1 \
    || { echo "  default check failed unexpectedly" >&2; return 1; }
  # Wrong response should fail
  if STUB_EXEC_OUTPUT=nope HELM="$tmp/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    KUBECONFIG="$tmp/kubeconfig" STUB_LOG_DIR="$tmp" \
    bash "$ROOT/scripts/controller.sh" check > /dev/null 2>&1; then
    echo "  check passed with wrong response" >&2; return 1
  fi
}

test_controller_sh_install_requires_tools() {
  local tmp="$1"
  _stub_kind "$tmp" > /dev/null
  _stub_controller_tools "$tmp"
  local out
  if out=$(HELM="/nonexistent/helm" FLUX="$tmp/flux" KUBECTL="$tmp/kubectl" \
    STUB_LOG_DIR="$tmp" bash "$ROOT/scripts/controller.sh" install 2>&1); then
    echo "  install passed with missing helm" >&2; return 1
  fi
  echo "$out" | grep -qi "required\|not found\|missing\|helm" \
    || { echo "  no useful error message, got: $out" >&2; return 1; }
  [[ ! -f "$tmp/helm.log" ]] || { echo "  helm was invoked despite missing tool" >&2; return 1; }
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
run_test "renovate managers match their targets"   test_renovate_managers_match_targets
run_test "renovate captures pinned versions"        test_renovate_captures_pinned_versions
run_test "renovate regexes reject invalid input"    test_renovate_regexes_reject_invalid_input
run_test "renovate extractVersion maps release tags" test_renovate_extract_version_templates
run_test "renovate groups Flux updates"             test_renovate_groups_flux_updates
run_test "renovate OCM CLI rule scoped to Dockerfile" test_renovate_ocm_cli_rule_scoped
run_test "e2e workflow isolates deploy" test_e2e_workflow_isolates_deploy
run_test "publish passes registry credentials via ocm config" test_publish_passes_registry_credentials_via_ocm_config
run_test "publish does not write registry secret" test_publish_does_not_write_registry_secret
run_test "publish without registry credentials uses discovery" test_publish_without_registry_credentials_uses_discovery
run_test "publish rejects partial registry credentials" test_publish_rejects_partial_registry_credentials
run_test "publish rejects missing repo and config" test_publish_rejects_missing_repo_and_config
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
run_test "docs product page" test_docs_product_page
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
run_test "docs versions page" test_docs_versions_page
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
run_test "pki signature is pem encoded" test_pki_signature_is_pem_encoded
run_test "pki verifier pins only root" test_pki_verifier_pins_only_root
run_test "pki scenarios" test_pki_scenarios
run_test "pki rotation keeps verifier config" test_pki_rotation_keeps_verifier_config
run_test "pki certs are reused" test_pki_certs_are_reused
run_test "pki reissues expiring leaf" test_pki_reissues_expiring_leaf
run_test "pki signature covers descriptor" test_pki_signature_covers_descriptor
run_test "pki signature survives transfer" test_pki_signature_survives_transfer
run_test "pki verify requires signature" test_pki_verify_requires_signature
run_test "pki own pki requires all vars" test_pki_own_pki_requires_all_vars
run_test "pki own pki uses supplied files" test_pki_own_pki_uses_supplied_files
run_test "pki show reports chain" test_pki_show_reports_chain
run_test "make pki target" test_make_pki_target
run_test "readme documents certificate-chain signing" test_readme_documents_certificate_chain_signing
run_test "git resource metadata" test_git_resource_metadata
run_test "git ref pinned at build time" test_git_ref_pinned_at_build_time
run_test "git upstream is deterministic" test_git_upstream_is_deterministic
run_test "git snapshot matches commit tree" test_git_snapshot_matches_commit_tree
run_test "git digest covers tree not commit" test_git_digest_covers_tree_not_commit
run_test "git signature binds commit label" test_git_signature_binds_commit_label
run_test "git audit matches snapshot" test_git_audit_matches_snapshot
run_test "git audit rejects wrong commit label" test_git_audit_rejects_wrong_commit_label
run_test "git audit requires signature" test_git_audit_requires_signature
run_test "git scenarios" test_git_scenarios
run_test "git transfer carries snapshot only" test_git_transfer_carries_snapshot_only
run_test "git uploader cannot copy git access" test_git_uploader_cannot_copy_git_access
run_test "git own repo requires both vars" test_git_own_repo_requires_both_vars
run_test "git own repo uses supplied repository" test_git_own_repo_uses_supplied_repository
run_test "git rejects sha256 repository" test_git_rejects_sha256_repository
run_test "git requires ocm 0.19" test_git_requires_ocm_019
run_test "git show reports provenance" test_git_show_reports_provenance
run_test "make git target" test_make_git_target
run_test "readme documents git repositories" test_readme_documents_git_repositories
run_test "oci layout is reproducible" test_oci_layout_is_reproducible
run_test "oci image resource metadata" test_oci_image_resource_metadata
run_test "oci resource digest is manifest digest" test_oci_resource_digest_is_manifest_digest
run_test "oci download yields oci layout" test_oci_download_yields_oci_layout
run_test "oci multiarch index references variants" test_oci_multiarch_index_references_variants
run_test "oci download requires signature" test_oci_download_requires_signature
run_test "oci signature covers image digest" test_oci_signature_covers_image_digest
run_test "oci transfer plan copy-resources leaves local images" test_oci_plan_copy_resources_leaves_local_images
run_test "oci transfer plan uploader rewrites references" test_oci_plan_uploader_rewrites_references
run_test "oci transfer to ctf keeps digests" test_oci_transfer_to_ctf_keeps_digests
run_test "oci inspect reports architectures" test_oci_inspect_reports_architectures
run_test "localization relocate rewrites access keeps digest" test_localization_relocate_rewrites_access_keeps_digest
run_test "localization readme documents three levels" test_localization_readme_documents_three_levels
run_test "make oci target" test_make_oci_target
run_test "readme documents oci images" test_readme_documents_oci_images
run_test "gpg signature is openpgp" test_gpg_signature_is_openpgp
run_test "gpg configs pin signer key" test_gpg_configs_pin_signer_key
run_test "gpg signs with subkey" test_gpg_signs_with_subkey
run_test "gpg keys are reused" test_gpg_keys_are_reused
run_test "gpg reissues expiring key" test_gpg_reissues_expiring_key
run_test "gpg leaves user keyring untouched" test_gpg_leaves_user_keyring_untouched
run_test "gpg scenarios" test_gpg_scenarios
run_test "gpg crosscheck with stock gpg" test_gpg_crosscheck_with_stock_gpg
run_test "gpg crosscheck does not cover descriptor" test_gpg_crosscheck_does_not_cover_descriptor
run_test "gpg signature covers descriptor" test_gpg_signature_covers_descriptor
run_test "gpg hash algorithm leaves descriptor digest" test_gpg_hash_algorithm_leaves_descriptor_digest
run_test "gpg multiple signatures" test_gpg_multiple_signatures
run_test "gpg signature survives transfer" test_gpg_signature_survives_transfer
run_test "gpg verify requires signature" test_gpg_verify_requires_signature
run_test "gpg download requires signature" test_gpg_download_requires_signature
run_test "gpg download checks digest" test_gpg_download_checks_digest
run_test "gpg own keys require both vars" test_gpg_own_keys_require_both_vars
run_test "gpg own keys use supplied files" test_gpg_own_keys_use_supplied_files
run_test "gpg show reports key" test_gpg_show_reports_key
run_test "make gpg target" test_make_gpg_target
run_test "readme documents gpg signing" test_readme_documents_gpg_signing
run_test "credentials build creates ctf" test_credentials_build_creates_ctf
run_test "credentials show lists consumer types" test_credentials_show_lists_consumer_types
run_test "credentials match exact wins over wildcard" test_credentials_match_exact_wins_over_wildcard
run_test "credentials match wildcard catches subpath" test_credentials_match_wildcard_catches_subpath
run_test "credentials match path star does not cross slash" test_credentials_match_path_star_does_not_cross_slash
run_test "credentials chain combines configs" test_credentials_chain_combines_configs
run_test "credentials wget identity hostname required" test_credentials_wget_identity_hostname_required
run_test "credentials wget identity port attribute" test_credentials_wget_identity_port_attribute
run_test "credentials generic config wraps multiple" test_credentials_generic_config_wraps_multiple
run_test "credentials scenarios matrix output" test_credentials_scenarios_matrix_output
run_test "make credentials target" test_make_credentials_target
run_test "readme documents credential system" test_readme_documents_credential_system
run_test "plugin capabilities returns access type" test_plugin_capabilities_returns_access_type
run_test "plugin healthz responds" test_plugin_healthz_responds
run_test "plugin build registers access type" test_plugin_build_registers_access_type
run_test "plugin download returns blob" test_plugin_download_returns_blob
run_test "plugin identity endpoint" test_plugin_identity_endpoint
run_test "plugin missing plugin fails gracefully" test_plugin_missing_plugin_fails_gracefully
run_test "plugin show lists capabilities" test_plugin_show_lists_capabilities
run_test "plugin scenarios correct response" test_plugin_scenarios_correct_response
run_test "plugin scenarios malformed response" test_plugin_scenarios_malformed_response
run_test "plugin loglevel debug shows registration" test_plugin_loglevel_debug_shows_registration
run_test "make plugin target" test_make_plugin_target
run_test "readme documents plugin demo" test_readme_documents_plugin_demo
run_test "registry docker available" test_registry_docker_available
run_test "registry start creates container" test_registry_start_creates_container
run_test "registry push component" test_registry_push_component_to_registry
run_test "registry get cv from registry" test_registry_get_cv_from_registry
run_test "registry sign in registry" test_registry_sign_in_registry
run_test "registry verify signed component" test_registry_verify_signed_component
run_test "registry pull downloads resource" test_registry_pull_downloads_resource
run_test "registry stop removes container" test_registry_stop_removes_container
run_test "registry push idempotent" test_registry_push_idempotent
run_test "registry transfer preserves resources" test_registry_transfer_preserves_resources
run_test "registry unsigned verify fails" test_registry_unsigned_verify_fails
run_test "registry oci url format" test_registry_oci_url_format
run_test "make registry target" test_make_registry_target
run_test "readme documents local oci registry" test_readme_documents_local_oci_registry
run_test "graph references span three repositories" test_graph_references_span_three_repositories
run_test "graph recursive get walks all levels" test_graph_recursive_get_walks_all_levels
run_test "graph resolver order first match wins" test_graph_resolver_order_first_match_wins
run_test "graph recursive transfer collects graph" test_graph_recursive_transfer_collects_graph
run_test "graph flat transfer is not self contained" test_graph_flat_transfer_is_not_self_contained
run_test "graph plan uploads shared reference once" test_graph_plan_uploads_shared_reference_once
run_test "graph transfer detects changed transitive reference" test_graph_transfer_detects_changed_transitive_reference
run_test "make graph target" test_make_graph_target
run_test "readme documents component graphs" test_readme_documents_component_graphs
run_test "github archive is deterministic" test_github_archive_is_deterministic
run_test "github access pinned at build time" test_github_access_pinned_at_build_time
run_test "github download matches digest" test_github_download_matches_digest
run_test "github ref moved keeps pinned commit" test_github_ref_moved_keeps_pinned_commit
run_test "github download rejects rewritten archive" test_github_download_rejects_rewritten_archive
run_test "github access needs api at consume time" test_github_access_needs_api_at_consume_time
run_test "github transfer copy inlines archive" test_github_transfer_copy_inlines_archive
run_test "github server port in use" test_github_server_port_in_use
run_test "github online is opt in" test_github_online_is_opt_in
run_test "github online release asset" test_github_online_release_asset
run_test "make github target" test_make_github_target
run_test "readme documents github access" test_readme_documents_github_access
run_test "normalisation matches ocm digest" test_normalisation_matches_ocm_digest
run_test "normalisation excludes unsigned fields" test_normalisation_excludes_unsigned_fields
run_test "normalisation label vs blob digests" test_normalisation_label_vs_blob_digests
run_test "normalisation reimplementation matches each variant" test_normalisation_reimplementation_matches_each_variant
run_test "normalisation rejects legacy v1" test_normalisation_rejects_legacy_v1
run_test "make normalisation target" test_make_normalisation_target
run_test "readme documents signing normalisation" test_readme_documents_signing_normalisation

run_test "s3 image pinned by digest" test_s3_image_pinned_by_digest
run_test "s3 docker skip without docker" test_s3_docker_skip_without_docker
run_test "s3 seed uploads object" test_s3_seed_uploads_object
run_test "s3 access records endpoint" test_s3_access_records_endpoint
run_test "s3 access v1 uses bucket key fields" test_s3_access_v1_uses_bucket_key_fields
run_test "s3 access v2 uses bucket name fields" test_s3_access_v2_uses_bucket_name_fields
run_test "s3 unversioned build warns no pin" test_s3_unversioned_build_warns_no_pin
run_test "s3 versioned bucket pins version" test_s3_versioned_bucket_pins_version
run_test "s3 input becomes local blob" test_s3_input_becomes_local_blob
run_test "s3 download v1 and v2" test_s3_download_v1_and_v2
run_test "s3 download rejects overwritten object" test_s3_download_rejects_overwritten_object
run_test "s3 pinned version survives overwrite" test_s3_pinned_version_survives_overwrite
run_test "s3 input works offline" test_s3_input_works_offline
run_test "s3 credentials required" test_s3_credentials_required
run_test "s3 glob star matches" test_s3_glob_star_matches
run_test "s3 doublestar not matched" test_s3_doublestar_not_matched
run_test "s3 transfer copies v2 only" test_s3_transfer_copies_v2_only
run_test "s3 stop removes container" test_s3_stop_removes_container
run_test "make s3 target" test_make_s3_target
run_test "readme documents s3 resources" test_readme_documents_s3_resources

run_test "none-access sha256 matches constructor label" test_none_access_provenance_json_matches_label
run_test "none-access resource has no digest in descriptor" test_none_access_resource_has_no_digest_in_descriptor
run_test "none-access build warns no digest processor" test_none_access_build_warns_no_digest_processor
run_test "none-access control resource downloads" test_none_access_control_resource_downloads
run_test "none-access download fails gracefully" test_none_access_download_fails_gracefully
run_test "none-access sign and verify" test_none_access_sign_and_verify
run_test "none-access digest not signed" test_none_access_digest_not_signed
run_test "none-access digest triggers warning" test_none_access_digest_triggers_warning
run_test "none-access lowercase warns missing digest" test_none_access_lowercase_warns_missing_digest
run_test "none-access versioned type is not none" test_none_access_versioned_type_is_not_none
run_test "none-access identity is signed" test_none_access_identity_is_signed
run_test "none-access label is signed" test_none_access_label_is_signed
run_test "none-access audit passes" test_none_access_audit_passes
run_test "none-access audit detects tamper" test_none_access_audit_detects_tamper
run_test "none-access transfer keeps none" test_none_access_transfer_keeps_none
run_test "none-access copy resources keeps none" test_none_access_copy_resources_keeps_none
run_test "make none-access target" test_make_none_access_target
run_test "readme documents none access" test_readme_documents_none_access
run_test "readme intro lists demos" test_readme_intro_lists_demos
run_test "readme is a docs index" test_readme_is_docs_index
run_test "docs links resolve" test_docs_links_resolve
run_test "license is apache 2.0" test_license_is_apache_2
run_test "contributing guide covers workflow" test_contributing_guide_covers_workflow

run_test "flux artifact is reproducible" test_flux_artifact_is_reproducible
run_test "flux artifact resource is flux oci layout" test_flux_artifact_resource_is_flux_oci_layout
run_test "flux artifact is not committed"     test_flux_artifact_is_not_committed
run_test "build generates flux artifact"      test_build_generates_flux_artifact
run_test "rgd mirrors localization and config" test_rgd_mirrors_localization_and_config
run_test "controller bootstrap wires published component" test_controller_bootstrap_wires_published_component
run_test "controller.sh installs stack" test_controller_sh_installs_stack
run_test "controller.sh applies bootstrap and checks app" test_controller_sh_applies_bootstrap_and_checks_app
run_test "controller.sh cluster lifecycle" test_controller_sh_cluster_lifecycle
run_test "controller.sh run deletes cluster it created"  test_controller_sh_run_deletes_created_cluster
run_test "controller.sh run keeps cluster with KEEP_CLUSTER" test_controller_sh_run_keep_cluster
run_test "controller.sh run reuses existing cluster"     test_controller_sh_run_reuses_existing_cluster
run_test "controller.sh down deletes cluster"            test_controller_sh_down_deletes_cluster
run_test "controller.sh rejects unknown subcommand"      test_controller_sh_rejects_unknown_subcommand
run_test "controller.sh apply sets target architecture"  test_controller_sh_apply_sets_target_architecture
run_test "controller.sh check fails without answer"      test_controller_sh_check_fails_without_answer
run_test "controller.sh install requires tools"          test_controller_sh_install_requires_tools
run_test "make controller target" test_make_controller_target
run_test "docs document controller stack" test_docs_document_controller_stack

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
