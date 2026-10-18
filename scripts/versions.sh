#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq

VERSIONS_COMPONENT="github.com/lioramilbaum/versions-demo"
VERSIONS_CTF="${VERSIONS_CTF:-$BUILD_DIR/versions-ctf}"
NIGHTLY_CTF="${NIGHTLY_CTF:-$BUILD_DIR/versions-nightly-ctf}"
VERSIONS_CONSTRUCTOR="$ROOT/components/versions/component-constructor.yaml"
VERSIONING_CONFIG="$ROOT/components/versions/versioning.ocmconfig"
DEFAULT_CONFIG="$BUILD_DIR/versions-default.ocmconfig"

RELEASE_VERSIONS=(0.1.0 0.2.0 0.10.0 1.0.0 1.1.0-rc.1)
NIGHTLY_VERSIONS=(r2 r9 r10 r100)

mkdir -p "$BUILD_DIR"

# Write an empty ocmconfig that disables ~/.ocmconfig discovery,
# so query results are not affected by the user's local config.
cat > "$DEFAULT_CONFIG" <<'CONFIG'
type: generic.config.ocm.software/v1
configurations: []
CONFIG

# Gate: --constraint was introduced in OCM 0.19.0; --semver-constraint (≤ 0.17) is not enough.
_ocm_help="$("$OCM" get cv --help 2>&1 || true)"
if ! grep -qE -- '^[[:space:]]+--constraint[[:space:]]' <<<"$_ocm_help"; then
  die "scripts/versions.sh requires OCM CLI >= 0.19.0 (needs get cv --constraint and versioning schemes)"
fi

_build() {
  rm -rf "$VERSIONS_CTF" "$NIGHTLY_CTF"
  for v in "${RELEASE_VERSIONS[@]}"; do
    # shellcheck disable=SC2086
    VERSION="$v" "$OCM" add cv \
      --repository "ctf::$VERSIONS_CTF" \
      --constructor "$VERSIONS_CONSTRUCTOR" \
      --config "$DEFAULT_CONFIG" \
      ${OCM_ADD_FLAGS:-} >/dev/null
  done
  for v in "${NIGHTLY_VERSIONS[@]}"; do
    # shellcheck disable=SC2086
    VERSION="$v" "$OCM" add cv \
      --repository "ctf::$NIGHTLY_CTF" \
      --constructor "$VERSIONS_CONSTRUCTOR" \
      --config "$VERSIONING_CONFIG" \
      ${OCM_ADD_FLAGS:-} >/dev/null
  done
}

# _query <ctf> <config> [extra flags…]
# Prints one version per line, newest first, or dies with a clear message on no match.
_query() {
  local ctf="$1" config="$2"
  shift 2
  local _stderr_file
  _stderr_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$_stderr_file'" RETURN
  if ! "$OCM" get cv "ctf::$ctf//$VERSIONS_COMPONENT" \
        --config "$config" -o json "$@" \
        2>"$_stderr_file" \
    | jq -r '.[].component.version'; then
    die "no version of $VERSIONS_COMPONENT in $ctf matches: $* — $(cat "$_stderr_file")"
  fi
}

_join() {
  paste -sd' ' -
}

_show() {
  local col1="release"
  printf '%s\t%s\t%s\n' "$col1" "all"                  "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     | _join)"
  printf '%s\t%s\t%s\n' "$col1" "latest"               "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     --latest | _join)"
  printf '%s\t%s\t%s\n' "$col1" "latest >= 0.0.0"      "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     --latest --constraint '>= 0.0.0' | _join)"
  printf '%s\t%s\t%s\n' "$col1" "^0.1"                 "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     --constraint '^0.1' | _join)"
  printf '%s\t%s\t%s\n' "$col1" ">= 0.2.0, < 1.0.0"   "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     --constraint '>= 0.2.0, < 1.0.0' | _join)"
  printf '%s\t%s\t%s\n' "$col1" "1.x"                  "$(_query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"     --constraint '1.x' | _join)"
  local col2="nightly"
  printf '%s\t%s\t%s\n' "$col2" "all"                  "$(_query "$NIGHTLY_CTF"   "$VERSIONING_CONFIG"  | _join)"
  printf '%s\t%s\t%s\n' "$col2" "latest"               "$(_query "$NIGHTLY_CTF"   "$VERSIONING_CONFIG"  --latest | _join)"
  printf '%s\t%s\t%s\n' "$col2" "all (no scheme)"      "$(_query "$NIGHTLY_CTF"   "$DEFAULT_CONFIG"     | _join)"
  printf '%s\t%s\t%s\n' "$col2" "latest (no scheme)"   "$(_query "$NIGHTLY_CTF"   "$DEFAULT_CONFIG"     --latest | _join)"
}

case "${1:-}" in
  build)  _build ;;
  list)   _query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"    ${2:+--constraint "$2"} ;;
  latest) _query "$VERSIONS_CTF"  "$DEFAULT_CONFIG"    --latest ${2:+--constraint "$2"} ;;
  nightly)
    printf '%s\t%s\t%s\n' "nightly" "all"                "$(_query "$NIGHTLY_CTF" "$VERSIONING_CONFIG" | _join)"
    printf '%s\t%s\t%s\n' "nightly" "latest"             "$(_query "$NIGHTLY_CTF" "$VERSIONING_CONFIG" --latest | _join)"
    printf '%s\t%s\t%s\n' "nightly" "all (no scheme)"    "$(_query "$NIGHTLY_CTF" "$DEFAULT_CONFIG" | _join)"
    printf '%s\t%s\t%s\n' "nightly" "latest (no scheme)" "$(_query "$NIGHTLY_CTF" "$DEFAULT_CONFIG" --latest | _join)"
    ;;
  show)   _show ;;
  *)      _build; echo ""; _show ;;
esac
