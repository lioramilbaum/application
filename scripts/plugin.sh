#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq python3 curl

PLUGIN_COMPONENT="github.com/lioramilbaum/plugin-demo"
PLUGIN_DEMO_CTF="${PLUGIN_DEMO_CTF:-$BUILD_DIR/plugin-ctf}"
PLUGIN_DEMO_OUT="${PLUGIN_DEMO_OUT:-$BUILD_DIR/plugin}"
PLUGIN_DIR="${PLUGIN_DIR:-$BUILD_DIR/plugins}"
PLUGIN_SRC="$ROOT/components/plugin/demo-store"
PLUGIN_DEMO_CONSTRUCTOR="$ROOT/components/plugin/component-constructor.yaml"
PLUGIN_ACCESS='{"type":"demo-store/v1alpha1","storeId":"my-store","blobId":"blob-001"}'
PLUGIN_CREDENTIALS='{"type":"Credentials/v1","properties":{"token":"demo-token"}}'

_plugin_ref() {
  echo "ctf::${1:-$PLUGIN_DEMO_CTF}//${PLUGIN_COMPONENT}:${VERSION}"
}

_ocm() {
  "$OCM" --plugin-directory "$PLUGIN_DIR" "$@" </dev/null
}

_write_credentials() {
  cat > "$PLUGIN_DEMO_OUT/credentials.ocmconfig" <<'EOF'
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: demo-store/v1alpha1
          storeId: my-store
        credentials:
          - type: Credentials/v1
            properties:
              token: demo-token
EOF
}

_install() {
  mkdir -p "$PLUGIN_DIR"
  install -m 0755 "$PLUGIN_SRC/demo-store-plugin" "$PLUGIN_DIR/demo-store-plugin"
  install -m 0644 "$PLUGIN_SRC/demo-store.json" "$PLUGIN_DIR/demo-store.json"
}

# _add_cv <ctf> <constructor> <config>
_add_cv() {
  _ocm add cv --repository "ctf::$1" --constructor "$2" --config "$3" >/dev/null
}

# _descriptor_digest <ref>
_descriptor_digest() {
  _ocm get cv "$1" -o json \
    | jq -r '.[0].component.resources[] | select(.name=="demo-blob") | .digest.value // empty'
}

_build() {
  _install
  rm -rf "${PLUGIN_DEMO_CTF:?}"
  _add_cv "$PLUGIN_DEMO_CTF" "$PLUGIN_DEMO_CONSTRUCTOR" "$PLUGIN_DEMO_OUT/credentials.ocmconfig"
  [[ -n "$(_descriptor_digest "$(_plugin_ref)")" ]] || \
    die "no digest recorded — is the demo-store plugin registered in $PLUGIN_DIR?"
}

# _fetch <ref> <out> <config>: download only, no digest check
_fetch() {
  _ocm download resource --identity name=demo-blob --output "$2" --config "$3" "$1" >/dev/null
}

# _check <ref> <file>: compares the file with the digest recorded in the descriptor
_check() {
  local want got
  want="$(_descriptor_digest "$1")"
  got="$(sha256 "$2")"
  [[ "$got" == "$want" ]] || die "digest mismatch for demo-blob: got $got, descriptor $want"
}

_download() {
  local stage
  stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  _fetch "$(_plugin_ref)" "$stage/demo-blob" "$PLUGIN_DEMO_OUT/credentials.ocmconfig"
  _check "$(_plugin_ref)" "$stage/demo-blob"
  rm -rf "$PLUGIN_DEMO_OUT/download"
  mv "$stage" "$PLUGIN_DEMO_OUT/download"
  trap - EXIT
  echo "$PLUGIN_DEMO_OUT/download/demo-blob"
}

_probe() {
  local log pid line sock body code i
  log="$(mktemp)"
  body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$log' '$body'" EXIT
  "$PLUGIN_DIR/demo-store-plugin" --config '{"id":"demo-store-plugin","type":"unix","idleTimeout":60000000000}' \
    >"$log" 2>&1 &
  pid=$!
  line=""
  # shellcheck disable=SC2034
  for i in $(seq 1 50); do
    line="$(grep -m1 '^http+unix://' "$log" || true)"
    [[ -n "$line" ]] && break
    sleep 0.1
  done
  if [[ -z "$line" ]]; then
    kill "$pid" 2>/dev/null || true
    rm -f "$log"
    die "demo-store plugin did not print its socket within 5s"
  fi
  sock="${line#http+unix://}"

  printf 'location\t%s\n' "$line"
  printf 'healthz\t%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" http://localhost/healthz)"
  printf 'identity\t%s\n' "$(curl -s --unix-socket "$sock" -X POST -H 'Content-Type: application/json' \
    -d "{\"type\":$PLUGIN_ACCESS}" http://localhost/identity | jq -c .)"
  code="$(curl -s -o "$body" -w '%{http_code}' --unix-socket "$sock" -X POST \
    -H 'Content-Type: application/json' -H "Authorization: $PLUGIN_CREDENTIALS" \
    -d "{\"resource\":{\"access\":$PLUGIN_ACCESS}}" http://localhost/resource/get)"
  printf 'get\t%s\t%s\t%s\n' "$code" "$(jq -r '.location.type // "-"' "$body")" "$(jq -r '.location.mediaType // "-"' "$body")"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$log" "$body"
}

_show() {
  local caps log
  caps="$("$PLUGIN_DIR/demo-store-plugin" capabilities)"
  jq -r '.capabilities[] | .type as $t | .supportedAccessTypes[] | ["capability", $t, .type] | @tsv' <<<"$caps"
  jq -r '.capabilities[0].supportedAccessTypes[0].jsonSchema' <<<"$caps" | base64 -d \
    | jq -r '["schema-required", (.required | join(","))] | @tsv'

  log="$(_ocm --loglevel debug get cv "$(_plugin_ref)" 2>&1 >/dev/null)"
  if grep -q 'msg="adding resource repository plugin"' <<<"$log"; then
    printf 'registered\tdemo-store-plugin\tresource repository\n'
  fi
  if grep -q 'msg="adding digest processor plugin"' <<<"$log"; then
    printf 'registered\tdemo-store-plugin\tdigest processor\n'
  fi

  _ocm get cv "$(_plugin_ref)" -o json \
    | jq -r '.[0].component.resources[] | select(.name=="demo-blob")
        | ["resource", .name, .access.type, .access.storeId, .access.blobId, ("sha256:" + .digest.value)] | @tsv'
}

# _classify <stderr-file>
_classify() {
  local text
  text="$(cat "$1" 2>/dev/null || true)"
  # OCM 0.19.1
  if grep -q 'failed to get plugin for typ' <<<"$text"; then
    echo no-plugin
  # OCM 0.19.1
  elif grep -q 'failed to unmarshal capabilities' <<<"$text"; then
    echo bad-capabilities
  # OCM 0.19.1
  elif grep -q 'failed to decode response from plugin' <<<"$text"; then
    echo malformed-response
  # OCM 0.19.1
  elif grep -q 'plugin returned status code 500' <<<"$text"; then
    echo plugin-error
  # OCM 0.19.1
  elif grep -q 'plugin returned status code 404' <<<"$text"; then
    echo not-found
  # OCM 0.19.1
  elif grep -q 'plugin returned status code 401' <<<"$text"; then
    echo unauthorized
  # OCM 0.19.1
  elif grep -q 'unsupported location type: remoteURL' <<<"$text"; then
    echo unsupported-location
  # OCM 0.19.1; the plugin answers 400 for a spec without blobId
  elif grep -qE "jsonschema validation failed|missing property 'blobId'|plugin returned status code 400" <<<"$text"; then
    echo invalid-spec
  elif grep -q 'digest mismatch' <<<"$text"; then
    echo digest-mismatch
  else
    echo error
  fi
}

# _scenario <name> <base-ctf>: prints "<name> <ocm> <check> <reason>"
_scenario() {
  local name="$1" base="$2" dir ref err config fault plugin_dir
  local ocm=ok check=- reason=-
  dir="$PLUGIN_DEMO_OUT/scenarios/$name"
  ref="$(_plugin_ref "$base")"
  err="$dir/stderr"
  mkdir -p "$dir"
  printf 'type: generic.config.ocm.software/v1\nconfigurations: []\n' > "$dir/empty.ocmconfig"

  case "$name" in
    unknown-blob|invalid-spec|no-credentials)
      # Build-time failures: the digest processor rejects the access spec or the credentials.
      local constructor="$PLUGIN_DEMO_CONSTRUCTOR"
      config="$PLUGIN_DEMO_OUT/credentials.ocmconfig"
      case "$name" in
        unknown-blob)
          constructor="$dir/constructor.yaml"
          sed 's/blobId: blob-001/blobId: blob-404/' "$PLUGIN_DEMO_CONSTRUCTOR" > "$constructor" ;;
        invalid-spec)
          constructor="$dir/constructor.yaml"
          sed '/blobId:/d' "$PLUGIN_DEMO_CONSTRUCTOR" > "$constructor" ;;
        no-credentials)
          config="$dir/empty.ocmconfig" ;;
      esac
      if ( _add_cv "$dir/ctf" "$constructor" "$config" ) 2>"$err"; then
        ocm=ok
      else
        ocm=fail
        reason="$(_classify "$err")"
      fi
      ;;
    config-locations)
      # Plugin locations in the config are not a discovery source; only --plugin-directory is.
      cat > "$dir/locations.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: plugin.config.ocm.software/v2alpha1
    locations:
      - $PLUGIN_DIR/demo-store-plugin
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: demo-store/v1alpha1
          storeId: my-store
        credentials:
          - type: Credentials/v1
            properties:
              token: demo-token
EOF
      if ( mkdir -p "$dir/home"; export HOME="$dir/home"
           "$OCM" download resource --identity name=demo-blob --output "$dir/blob" \
             --config "$dir/locations.ocmconfig" "$ref" </dev/null >/dev/null ) 2>"$err"; then
        ocm=ok
      else
        ocm=fail
        reason="$(_classify "$err")"
      fi
      ;;
    correct|missing-plugin|malformed-capabilities|malformed-response|plugin-error|unsupported-location|tampered-content)
      plugin_dir="$PLUGIN_DIR" fault=""
      case "$name" in
        missing-plugin) plugin_dir="$dir/empty"; mkdir -p "$plugin_dir" ;;
        malformed-capabilities) fault=capabilities ;;
        malformed-response) fault=garbage ;;
        plugin-error) fault=error ;;
        unsupported-location) fault=remote-url ;;
        tampered-content) fault=tamper ;;
      esac
      if ( export PLUGIN_DIR="$plugin_dir" DEMO_STORE_FAULT="$fault"
           _fetch "$ref" "$dir/blob" "$PLUGIN_DEMO_OUT/credentials.ocmconfig" ) 2>"$err"; then
        ocm=ok
        if ( _check "$ref" "$dir/blob" ) 2>"$dir/check.stderr"; then
          check=ok
        else
          check=fail
          reason="$(_classify "$dir/check.stderr")"
        fi
      else
        ocm=fail
        reason="$(_classify "$err")"
      fi
      ;;
    *)
      die "unknown scenario: $name" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$name" "$ocm" "$check" "$reason"
}

_scenarios() {
  local all="correct missing-plugin config-locations malformed-capabilities malformed-response plugin-error unsupported-location unknown-blob invalid-spec no-credentials tampered-content"
  local names base name
  if [[ $# -gt 0 ]]; then
    names="$*"
  else
    names="$all"
  fi
  _install
  rm -rf "$PLUGIN_DEMO_OUT/scenarios"
  mkdir -p "$PLUGIN_DEMO_OUT/scenarios"
  base="$PLUGIN_DEMO_OUT/scenarios/base-ctf"
  _add_cv "$base" "$PLUGIN_DEMO_CONSTRUCTOR" "$PLUGIN_DEMO_OUT/credentials.ocmconfig"
  for name in $names; do
    _scenario "$name" "$base"
  done
}

mkdir -p "$PLUGIN_DEMO_OUT"
_write_credentials

case "${1:-}" in
  install)   _install ;;
  build)     _build ;;
  download)  _download ;;
  probe)     _probe ;;
  show)      _show ;;
  scenarios) _scenarios "${@:2}" ;;
  *)         _build; _download >/dev/null; echo; _show ;;
esac
