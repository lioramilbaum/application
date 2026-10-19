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
  echo "ctf::${1:-$REGISTRY_DEMO_CTF}//${REGISTRY_COMPONENT}:${VERSION}"
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

case "${1:-}" in
  start)   _start ;;
  stop)    _stop ;;
  build)   _build ;;
  push)    _push ;;
  sign)    _sign ;;
  verify)  _verify ;;
  pull)    _pull ;;
  show)    _show ;;
  *)       _require_docker; _start >/dev/null; _build; _push >/dev/null; _sign; _verify >/dev/null; _pull >/dev/null; _show ;;
esac
