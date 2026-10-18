#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq curl python3

# Gate: checksum.http.config is honoured from OCM 0.19.0; older releases download tampered bytes silently.
_ocm_ver="$("$OCM" version 2>/dev/null | sed -n 's/^[[:space:]]*Version:[[:space:]]*//p' | head -n1 || true)"
_ocm_ver="${_ocm_ver#v}"
_ocm_ver="${_ocm_ver%%-*}"
IFS=. read -r _ocm_major _ocm_minor _ <<<"$_ocm_ver"
# Allow source builds (OCM built from main reports "(devel)")
if [[ "$_ocm_ver" != *"devel"* ]] && { [[ ! "${_ocm_major:-}" =~ ^[0-9]+$ || ! "${_ocm_minor:-}" =~ ^[0-9]+$ ]] \
  || (( _ocm_major == 0 && _ocm_minor < 19 )); }; then
  die "scripts/wget.sh requires OCM CLI >= 0.19.0 (found: ${_ocm_ver:-unknown}) — older releases ignore checksum.http.config and download tampered bytes without error"
fi

WGET_COMPONENT="github.com/lioramilbaum/wget-demo"
WGET_DEMO_CTF="${WGET_DEMO_CTF:-$BUILD_DIR/wget-ctf}"
WGET_DEMO_OUT="${WGET_DEMO_OUT:-$BUILD_DIR/wget}"
WGET_DEMO_PORT="${WGET_DEMO_PORT:-18431}"
WGET_DEMO_URL="${WGET_DEMO_URL:-http://127.0.0.1:${WGET_DEMO_PORT}}"
WGET_DEMO_DIGEST="${WGET_DEMO_DIGEST:-none}"
WGET_DEMO_CHECKSUM_MODE="${WGET_DEMO_CHECKSUM_MODE:-Prefer}"
WGET_DEMO_CONSTRUCTOR="${WGET_DEMO_CONSTRUCTOR:-$ROOT/components/wget/component-constructor.yaml}"
UPSTREAM_DIR="$ROOT/components/wget/upstream"
TRANSFER_CONFIG="$ROOT/components/wget/transfer.ocmconfig"
RESOURCES=(release-notes hello-world-page)
export ROOT VERSION WGET_DEMO_URL

[[ "$WGET_DEMO_PORT" =~ ^[0-9]+$ ]] || die "WGET_DEMO_PORT must be numeric (got: $WGET_DEMO_PORT)"
case "$WGET_DEMO_CHECKSUM_MODE" in
  Require|Prefer|Skip) ;;
  *) die "WGET_DEMO_CHECKSUM_MODE must be Require, Prefer or Skip" ;;
esac

_wget_component_ref() {
  echo "ctf::${WGET_DEMO_CTF}//${WGET_COMPONENT}:${VERSION}"
}

# Every OCM call reads this file so ~/.ocmconfig discovery is not used.
_ocm_config_args() {
  echo "--config $WGET_DEMO_OUT/checksum.ocmconfig"
}

# _generate_checksum_config <mode> <outfile>
_generate_checksum_config() {
  local mode="$1" outfile="$2"
  mkdir -p "$(dirname "$outfile")"
  cat > "$outfile" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: checksum.http.config.ocm.software/v1alpha1
    mode: $mode
EOF
}

_stage() {
  mkdir -p "$WGET_DEMO_OUT"
  rm -rf "$WGET_DEMO_OUT/upstream"
  cp -R "$UPSTREAM_DIR" "$WGET_DEMO_OUT/upstream"
}

_server_start() {
  [[ -d "$WGET_DEMO_OUT/upstream" ]] || die "run scripts/wget.sh build first"
  printf '%s\n' "$WGET_DEMO_DIGEST" > "$WGET_DEMO_OUT/digest-mode"
  python3 -I "$ROOT/scripts/upstream-server.py" \
    --root "$WGET_DEMO_OUT/upstream" \
    --port "$WGET_DEMO_PORT" \
    --digest-file "$WGET_DEMO_OUT/digest-mode" \
    >"$WGET_DEMO_OUT/server.log" 2>&1 &
  WGET_SERVER_PID=$!
  trap _server_stop EXIT
  local _
  for _ in $(seq 1 10); do
    if ! kill -0 "$WGET_SERVER_PID" 2>/dev/null; then
      die "upstream server failed to start on 127.0.0.1:${WGET_DEMO_PORT} (port in use?)"$'\n'"$(tail -n 5 "$WGET_DEMO_OUT/server.log")"
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${WGET_DEMO_PORT}/-/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  die "upstream server not ready on 127.0.0.1:${WGET_DEMO_PORT} after 5s"
}

_server_stop() {
  kill "${WGET_SERVER_PID:-}" 2>/dev/null || true
  wait "${WGET_SERVER_PID:-}" 2>/dev/null || true
  trap - EXIT
}

# _classify <stderr-file>
_classify() {
  local text
  text="$(cat "$1" 2>/dev/null || true)"
  # OCM 0.19.1
  if grep -qE 'does not match the source-advertised algorithm' <<<"$text"; then
    echo algorithm-mismatch
  # OCM 0.19.1
  elif grep -qE 'no advertised checksum|no checksum could be obtained' <<<"$text"; then
    echo missing-checksum
  # OCM 0.19.1
  elif grep -qE 'checksum mismatch|does not match source-advertised|digest mismatch|provided digest' <<<"$text"; then
    echo mismatch
  # OCM 0.19.1
  elif grep -q 'status 401' <<<"$text"; then
    echo unauthorized
  else
    echo error
  fi
}

_sign_cv() {
  # shellcheck disable=SC2046
  "$OCM" sign cv \
    --config "$BUILD_DIR/sign.ocmconfig" \
    $(_ocm_config_args) \
    --signature default \
    "$1" < /dev/null
}

_verify() {
  # shellcheck disable=SC2046
  "$OCM" verify cv \
    --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" \
    $(_ocm_config_args) \
    --signature default \
    "$(_wget_component_ref)" < /dev/null
}

_build() {
  rm -rf "$WGET_DEMO_CTF"
  _stage
  _server_start
  # shellcheck disable=SC2046,SC2086
  "$OCM" add cv \
    --repository "ctf::$WGET_DEMO_CTF" \
    --constructor "$WGET_DEMO_CONSTRUCTOR" \
    $(_ocm_config_args) \
    ${OCM_ADD_FLAGS:-}
  _server_stop
}

_sign() {
  _sign_cv "$(_wget_component_ref)"
}

_download() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify
  _server_start

  local stage_dir resource cv_json rc reason algo value actual
  stage_dir="$(mktemp -d "$WGET_DEMO_OUT/.download.XXXXXX")"
  # shellcheck disable=SC2046
  cv_json="$("$OCM" get cv "$(_wget_component_ref)" -o json $(_ocm_config_args))"

  for resource in "${RESOURCES[@]}"; do
    rc=0
    # shellcheck disable=SC2046
    "$OCM" download resource \
      --identity "name=$resource" \
      --output "$stage_dir/$resource" \
      $(_ocm_config_args) \
      "$(_wget_component_ref)" \
      2>"$stage_dir/$resource.stderr" >/dev/null || rc=$?
    if (( rc != 0 )); then
      reason="$(_classify "$stage_dir/$resource.stderr")"
      cat "$stage_dir/$resource.stderr" >&2
      rm -rf "$stage_dir"
      die "$resource: download rejected ($reason)"
    fi
    rm -f "$stage_dir/$resource.stderr"

    algo="$(jq -r --arg r "$resource" \
      '.[0].component.resources[] | select(.name==$r) | .digest.hashAlgorithm' <<<"$cv_json")"
    value="$(jq -r --arg r "$resource" \
      '.[0].component.resources[] | select(.name==$r) | .digest.value' <<<"$cv_json")"
    # Only SHA-256 is supported by this check; other algorithms are left to OCM.
    if [[ "$algo" == "SHA-256" ]]; then
      actual="$(sha256 "$stage_dir/$resource")"
      if [[ "$actual" != "$value" ]]; then
        rm -rf "$stage_dir"
        die "$resource: download rejected (mismatch)"
      fi
    fi
  done

  rm -rf "$WGET_DEMO_OUT/download"
  mv "$stage_dir" "$WGET_DEMO_OUT/download"
  _server_stop
  echo "$WGET_DEMO_OUT/download/release-notes"
  echo "$WGET_DEMO_OUT/download/hello-world-page"
}

_tamper() {
  [[ -d "$WGET_DEMO_OUT/upstream" ]] || die "run scripts/wget.sh build first"
  local page="$WGET_DEMO_OUT/upstream/index.html"
  printf '%s\n' '<!-- changed upstream -->' >> "$page"
  sha256 "$page"
}

_checksum() {
  local rows=("none Skip" "none Prefer" "none Require" "sha-256 Require" "wrong Prefer" "wrong Skip" "sha-512 Prefer")
  local dir="$WGET_DEMO_OUT/checksum"
  local row header mode cfg ctf err algo

  rm -rf "$dir"
  mkdir -p "$dir"
  _stage
  _server_start

  for row in "${rows[@]}"; do
    read -r header mode <<<"$row"
    cfg="$dir/checksum-${header}-${mode}.ocmconfig"
    ctf="$dir/${header}-${mode}-ctf"
    err="$dir/${header}-${mode}.stderr"
    _generate_checksum_config "$mode" "$cfg"
    printf '%s\n' "$header" > "$WGET_DEMO_OUT/digest-mode"

    # shellcheck disable=SC2086
    if "$OCM" add cv \
      --repository "ctf::$ctf" \
      --constructor "$WGET_DEMO_CONSTRUCTOR" \
      --config "$cfg" \
      ${OCM_ADD_FLAGS:-} >/dev/null 2>"$err"; then
      algo="$("$OCM" get cv "ctf::$ctf//$WGET_COMPONENT:$VERSION" -o json --config "$cfg" \
        | jq -r '.[0].component.resources[] | select(.name=="hello-world-page") | .digest.hashAlgorithm')"
      printf '%s\t%s\tok\t%s\n' "$header" "$mode" "$algo"
    else
      printf '%s\t%s\tfail\t%s\n' "$header" "$mode" "$(_classify "$err")"
    fi
  done
  _server_stop
}

_transfer() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify
  _server_start

  local ref_ctf="$WGET_DEMO_OUT/transfer-ref-ctf"
  local copy_ctf="$WGET_DEMO_OUT/transfer-copy-ctf"
  rm -rf "$ref_ctf" "$copy_ctf"

  # shellcheck disable=SC2046
  "$OCM" transfer cv $(_ocm_config_args) "$(_wget_component_ref)" "ctf::$ref_ctf" >/dev/null
  # shellcheck disable=SC2046
  "$OCM" transfer cv $(_ocm_config_args) --config "$TRANSFER_CONFIG" \
    "$(_wget_component_ref)" "ctf::$copy_ctf" >/dev/null
  _server_stop

  local label dir
  for label in reference copy; do
    dir="$ref_ctf"
    [[ "$label" == copy ]] && dir="$copy_ctf"
    # shellcheck disable=SC2046
    "$OCM" get cv "ctf::$dir//$WGET_COMPONENT:$VERSION" -o json $(_ocm_config_args) \
      | jq -r --arg l "$label" \
        '.[0].component.resources[] | [$l, .name, .relation, .access.type] | @tsv'
  done
}

_show() {
  # shellcheck disable=SC2046
  "$OCM" get cv "$(_wget_component_ref)" -o json $(_ocm_config_args) \
    | jq -r '.[0].component.resources[]
      | [.name, .relation, .access.type, .digest.hashAlgorithm, .digest.value] | @tsv'
}

mkdir -p "$WGET_DEMO_OUT"
_generate_checksum_config "$WGET_DEMO_CHECKSUM_MODE" "$WGET_DEMO_OUT/checksum.ocmconfig"

case "${1:-}" in
  build)    _build ;;
  sign)     _sign ;;
  verify)   _verify ;;
  download) _download ;;
  tamper)   _tamper ;;
  restore)  _stage ;;
  checksum) _checksum ;;
  transfer) _transfer ;;
  show)     _show ;;
  *)        _build; _sign; _verify; SKIP_VERIFY=1 _download; echo ""; _show ;;
esac
