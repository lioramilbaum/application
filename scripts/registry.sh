#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq curl

REGISTRY_COMPONENT="github.com/lioramilbaum/registry-demo"
REGISTRY_SIGNATURE="default"
REGISTRY_NAME="${REGISTRY_NAME:-ocm-demo-registry}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373}"
REGISTRY_HOST="${REGISTRY_HOST:-127.0.0.1}"
REGISTRY_PORT="${REGISTRY_PORT:-5055}"
REGISTRY_PATH="${REGISTRY_PATH:-ocm}"
REGISTRY_DEMO_CTF="${REGISTRY_DEMO_CTF:-$BUILD_DIR/registry-ctf}"
REGISTRY_DEMO_OUT="${REGISTRY_DEMO_OUT:-$BUILD_DIR/registry}"
REGISTRY_REPO="oci::http://${REGISTRY_HOST}:${REGISTRY_PORT}/${REGISTRY_PATH}"
REGISTRY_DEMO_CONSTRUCTOR="$REGISTRY_DEMO_OUT/component-constructor.yaml"
REGISTRY_LAYER_COMPONENT="github.com/lioramilbaum/registry-layer-demo"
REGISTRY_LAYER_REPO="${REGISTRY_PATH}/layers/release-notes"
REGISTRY_LAYER_CTF="${REGISTRY_LAYER_CTF:-$BUILD_DIR/registry-layer-ctf}"
REGISTRY_LAYER_CONSTRUCTOR="$REGISTRY_DEMO_OUT/layer-constructor.yaml"

_docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

_require_docker() {
  if ! _docker_available; then
    echo "skip: Docker is not available; the local registry demo needs a Docker daemon" >&2
    exit 0
  fi
}

_ctf_ref() {
  echo "ctf::${REGISTRY_DEMO_CTF}//${REGISTRY_COMPONENT}:${VERSION}"
}

_registry_ref() {
  echo "oci::http://${REGISTRY_HOST}:${REGISTRY_PORT}/${REGISTRY_PATH}//${REGISTRY_COMPONENT}:${VERSION}"
}

_running() {
  docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null | grep -q true
}

_wait_ready() {
  local _
  for _ in $(seq 1 40); do
    curl -fsS -o /dev/null "http://$REGISTRY_HOST:$REGISTRY_PORT/v2/" 2>/dev/null && return 0
    sleep 0.25
  done
  die "registry not reachable at http://$REGISTRY_HOST:$REGISTRY_PORT; run scripts/registry.sh start"
}

_write_constructor() {
  cat > "$REGISTRY_DEMO_CONSTRUCTOR" <<'REGISTRY_CONSTRUCTOR_EOF'
# Demo component for local OCI registry demo.
name: github.com/lioramilbaum/registry-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes
    type: blob
    version: ${VERSION}
    input:
      type: UTF8/v1
      text: "github.com/lioramilbaum/registry-demo ${VERSION}"
REGISTRY_CONSTRUCTOR_EOF
}

_start() {
  _require_docker
  if _running; then
    _wait_ready
    echo "$REGISTRY_REPO"
    return
  fi
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$REGISTRY_NAME" \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    "$REGISTRY_IMAGE" >/dev/null \
    || die "failed to start registry (is port $REGISTRY_PORT in use?)"
  _wait_ready
  echo "$REGISTRY_REPO"
}

_stop() {
  _require_docker
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
}

_build() {
  _write_constructor
  rm -rf "${REGISTRY_DEMO_CTF:?}"
  "$OCM" add cv \
    --repository "ctf::$REGISTRY_DEMO_CTF" \
    --constructor "$REGISTRY_DEMO_CONSTRUCTOR" \
    --config "$BUILD_DIR/verify.ocmconfig" </dev/null >/dev/null
}

_push() {
  [[ -d "$REGISTRY_DEMO_CTF" ]] || _build
  _wait_ready
  # OCM 0.19.1: re-pushing from an unsigned CTF drops signatures added in the registry.
  "$OCM" transfer cv \
    --config "$BUILD_DIR/verify.ocmconfig" \
    "$(_ctf_ref)" "$REGISTRY_REPO" </dev/null >/dev/null
  _registry_ref
}

_sign() {
  "$OCM" sign cv \
    --config "$BUILD_DIR/sign.ocmconfig" \
    --signature "$REGISTRY_SIGNATURE" \
    "$(_registry_ref)" </dev/null >/dev/null
}

_verify() {
  "$OCM" verify cv \
    --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" \
    --signature "$REGISTRY_SIGNATURE" \
    "$(_registry_ref)" </dev/null
}

_pull() {
  _verify >/dev/null
  local stage
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  "$OCM" download resource \
    --identity name=release-notes \
    --output "$stage/release-notes" \
    "$(_registry_ref)" </dev/null >/dev/null
  # Verify digest
  local desc_digest actual_digest
  desc_digest="$("$OCM" get cv "$(_registry_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name=="release-notes") | .digest.value')"
  actual_digest="$(shasum -a 256 "$stage/release-notes" | cut -d' ' -f1)"
  [[ "$desc_digest" == "$actual_digest" ]] || die "digest mismatch: expected $desc_digest got $actual_digest"
  rm -rf "${REGISTRY_DEMO_OUT:?}/download"
  mkdir -p "$REGISTRY_DEMO_OUT"
  mv "$stage" "$REGISTRY_DEMO_OUT/download"
  # Transfer back to CTF
  rm -rf "${REGISTRY_DEMO_OUT:?}/pulled-ctf"
  "$OCM" transfer cv "$(_registry_ref)" "ctf::$REGISTRY_DEMO_OUT/pulled-ctf" </dev/null >/dev/null
  echo "$REGISTRY_DEMO_OUT/download/release-notes"
  echo "ctf::$REGISTRY_DEMO_OUT/pulled-ctf"
}

_show() {
  local base="http://$REGISTRY_HOST:$REGISTRY_PORT" repo tags cv_json
  printf 'repository\t%s\n' "$REGISTRY_REPO"
  curl -fsS "$base/v2/_catalog" | jq -r '(.repositories // [])[]' | while IFS= read -r repo; do
    tags="$(curl -fsS "$base/v2/$repo/tags/list" | jq -r '(.tags // []) | join(",")')"
    printf 'oci\t%s\t%s\n' "$repo" "$tags"
  done
  cv_json="$("$OCM" get cv "$(_registry_ref)" -o json </dev/null)"
  jq -r '.[0].component | ["component", .name, .version, .provider] | @tsv' <<<"$cv_json"
  jq -r '.[0].component.resources[] | ["resource", .name, .type, .access.type, ("sha256:" + .digest.value)] | @tsv' <<<"$cv_json"
  jq -r '.[0].signatures[]? | ["signature", .name, .signature.algorithm, .digest.value] | @tsv' <<<"$cv_json"
}

mkdir -p "$REGISTRY_DEMO_OUT"

# _blob_push <repo> <file> <digest> — upload a blob with the OCI distribution API
_blob_push() {
  local repo="$1" file="$2" digest="$3" base location sep
  base="http://$REGISTRY_HOST:$REGISTRY_PORT"
  location="$(curl -fsS -o /dev/null -D - -X POST "$base/v2/$repo/blobs/uploads/" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
  [[ -n "$location" ]] || die "registry returned no upload location for $repo"
  case "$location" in
    /*) location="$base$location" ;;
  esac
  sep='?'
  [[ "$location" != *\?* ]] || sep='&'
  curl -fsS -o /dev/null -X PUT -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" "${location}${sep}digest=$digest"
}

# _layer_push — push the config and layer blobs and an image manifest; prints the layer digest
_layer_push() {
  local dir="$REGISTRY_DEMO_OUT/layer" base layer_size cfg_size layer_digest cfg_digest
  base="http://$REGISTRY_HOST:$REGISTRY_PORT"
  mkdir -p "$dir"
  printf 'github.com/lioramilbaum/registry-demo %s (layer)\n' "$VERSION" > "$dir/release-notes.txt"
  printf '{}' > "$dir/config.json"
  layer_digest="sha256:$(sha256 "$dir/release-notes.txt")"
  layer_size="$(wc -c < "$dir/release-notes.txt" | tr -d ' ')"
  cfg_digest="sha256:$(sha256 "$dir/config.json")"
  cfg_size="$(wc -c < "$dir/config.json" | tr -d ' ')"

  _blob_push "$REGISTRY_LAYER_REPO" "$dir/config.json" "$cfg_digest"
  _blob_push "$REGISTRY_LAYER_REPO" "$dir/release-notes.txt" "$layer_digest"

  # Without a manifest the repository has no tags, so it would not look like an image repository.
  jq -n --arg cd "$cfg_digest" --argjson cs "$cfg_size" --arg ld "$layer_digest" --argjson ls "$layer_size" '{
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {mediaType: "application/vnd.oci.empty.v1+json", digest: $cd, size: $cs},
    layers: [{mediaType: "text/plain", digest: $ld, size: $ls}]
  }' > "$dir/manifest.json"
  curl -fsS -o /dev/null -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary "@$dir/manifest.json" "$base/v2/$REGISTRY_LAYER_REPO/manifests/$VERSION"

  echo "$layer_digest"
}

_layer_ctf_ref() {
  echo "ctf::${REGISTRY_LAYER_CTF}//${REGISTRY_LAYER_COMPONENT}:${VERSION}"
}

_write_layer_constructor() {
  cat > "$REGISTRY_LAYER_CONSTRUCTOR" <<'REGISTRY_LAYER_CONSTRUCTOR_EOF'
# Layer demo: the resource references one OCI layer blob by digest; OCM fills in size.
name: github.com/lioramilbaum/registry-layer-demo
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: release-notes-layer
    type: blob
    version: ${VERSION}
    access:
      type: OCIImageLayer/v1
      ref: ${REGISTRY_LAYER_REF}
      mediaType: text/plain
      digest: ${REGISTRY_LAYER_DIGEST}
REGISTRY_LAYER_CONSTRUCTOR_EOF
}

_layer() {
  _wait_ready
  REGISTRY_LAYER_DIGEST="$(_layer_push)"
  export REGISTRY_LAYER_DIGEST
  export REGISTRY_LAYER_REF="http://$REGISTRY_HOST:$REGISTRY_PORT/$REGISTRY_LAYER_REPO"
  local layer_size
  layer_size="$(wc -c < "$REGISTRY_DEMO_OUT/layer/release-notes.txt" | tr -d ' ')"

  rm -rf "${REGISTRY_LAYER_CTF:?}"
  _write_layer_constructor
  "$OCM" add cv \
    --repository "ctf::$REGISTRY_LAYER_CTF" \
    --constructor "$REGISTRY_LAYER_CONSTRUCTOR" \
    --config "$BUILD_DIR/verify.ocmconfig" </dev/null >/dev/null
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_layer_ctf_ref)" </dev/null >/dev/null
  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" "$(_layer_ctf_ref)" </dev/null >/dev/null

  # Download the layer and check its bytes against the descriptor digest.
  local out desc_json desc_digest actual_digest acc_type acc_digest acc_size
  out="$REGISTRY_DEMO_OUT/layer-download"
  rm -rf "${out:?}"
  mkdir -p "$out"
  "$OCM" download resource \
    --identity name=release-notes-layer \
    --output "$out/release-notes-layer" \
    "$(_layer_ctf_ref)" </dev/null >/dev/null
  desc_json="$("$OCM" get cv "$(_layer_ctf_ref)" -o json </dev/null \
    | jq -c '.[0].component.resources[] | select(.name=="release-notes-layer")')"
  desc_digest="$(jq -r '.digest.value' <<<"$desc_json")"
  actual_digest="$(sha256 "$out/release-notes-layer")"
  [[ "$desc_digest" == "$actual_digest" ]] || die "digest mismatch: expected $desc_digest got $actual_digest"
  acc_type="$(jq -r '.access.type' <<<"$desc_json")"
  acc_digest="$(jq -r '.access.digest' <<<"$desc_json")"
  acc_size="$(jq -r '.access.size' <<<"$desc_json")"

  # Copy into a CTF with the localblob uploader, which inlines the layer as LocalBlob/v1.
  local cfg="$REGISTRY_DEMO_OUT/layer-transfer.ocmconfig" copied="$REGISTRY_DEMO_OUT/layer-copied-ctf"
  cat > "$cfg" <<'EOF'
type: generic.config.ocm.software/v1
configurations:
  - type: localblob.uploader.transfer.config.ocm.software/v1alpha1
    match: resource.access.isType("OCIImageLayer")
EOF
  rm -rf "${copied:?}"
  "$OCM" --config "$cfg" transfer cv "$(_layer_ctf_ref)" "ctf::$copied" </dev/null >/dev/null
  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
    "ctf::$copied//$REGISTRY_LAYER_COMPONENT:$VERSION" </dev/null >/dev/null
  local copied_type
  copied_type="$("$OCM" get cv "ctf::$copied//$REGISTRY_LAYER_COMPONENT:$VERSION" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name=="release-notes-layer") | .access.type')"

  # A digest the registry does not hold must fail to resolve.
  local fake err_file reason
  fake="sha256:$(printf '0%.0s' {1..64})"
  err_file="$(mktemp)"
  rm -rf "${REGISTRY_DEMO_OUT:?}/layer-missing-ctf"
  if REGISTRY_LAYER_DIGEST="$fake" "$OCM" add cv \
      --repository "ctf::$REGISTRY_DEMO_OUT/layer-missing-ctf" \
      --constructor "$REGISTRY_LAYER_CONSTRUCTOR" \
      --config "$BUILD_DIR/verify.ocmconfig" </dev/null >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    die "ocm add cv accepted a layer digest the registry does not hold"
  fi
  if grep -q 'does not exist' "$err_file"; then reason=not-found; else reason=error; fi
  rm -f "$err_file"

  printf 'layer\t%s\t%s\t%s\n' "$REGISTRY_LAYER_REPO" "$REGISTRY_LAYER_DIGEST" "$layer_size"
  printf 'resource\trelease-notes-layer\t%s\t%s\t%s\n' "$acc_type" "$acc_digest" "$acc_size"
  printf 'download\trelease-notes-layer\tok\n'
  printf 'copied\trelease-notes-layer\t%s\n' "$copied_type"
  printf 'missing-layer\trelease-notes-layer\t%s\n' "$reason"
}

case "${1:-}" in
  start)   _start ;;
  stop)    _stop ;;
  build)   _build ;;
  push)    _push ;;
  sign)    _sign ;;
  verify)  _verify ;;
  pull)    _pull ;;
  show)    _show ;;
  layer)   _layer ;;
  *)       _require_docker; _start >/dev/null; _build; _push >/dev/null; _sign; _verify >/dev/null; _pull >/dev/null; _layer >/dev/null; _show ;;
esac
