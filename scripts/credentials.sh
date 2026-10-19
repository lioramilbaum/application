#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq curl python3

CREDENTIALS_COMPONENT="github.com/lioramilbaum/credentials-demo"
CREDENTIALS_DEMO_CTF="${CREDENTIALS_DEMO_CTF:-$BUILD_DIR/credentials-ctf}"
CREDENTIALS_DEMO_OUT="${CREDENTIALS_DEMO_OUT:-$BUILD_DIR/credentials}"
CREDENTIALS_DEMO_PORT="${CREDENTIALS_DEMO_PORT:-18441}"
CREDENTIALS_DEMO_CONSTRUCTOR="$ROOT/components/credentials/component-constructor.yaml"
CREDENTIALS_OCI_LAYOUT="$ROOT/components/oci/hello-oci-multiarch.oci.tar"

_cred_ref() {
  echo "ctf::${CREDENTIALS_DEMO_CTF}//${CREDENTIALS_COMPONENT}:${VERSION}"
}

# Passing an explicit --config turns off ~/.ocmconfig discovery, so every probe is self-contained.
_empty_config() {
  cat > "$CREDENTIALS_DEMO_OUT/empty.ocmconfig" <<'EOF'
type: generic.config.ocm.software/v1
configurations: []
EOF
}

_server_start() {
  mkdir -p "$CREDENTIALS_DEMO_OUT/upstream"
  printf 'none\n' > "$CREDENTIALS_DEMO_OUT/digest-mode"
  python3 -I "$ROOT/scripts/upstream-server.py" \
    --root "$CREDENTIALS_DEMO_OUT/upstream" \
    --port "$CREDENTIALS_DEMO_PORT" \
    --digest-file "$CREDENTIALS_DEMO_OUT/digest-mode" \
    --auth-log "$CREDENTIALS_DEMO_OUT/requests.log" \
    >"$CREDENTIALS_DEMO_OUT/server.log" 2>&1 &
  CREDENTIALS_SERVER_PID=$!
  trap _server_stop EXIT
  local _
  for _ in $(seq 1 6); do
    if ! kill -0 "$CREDENTIALS_SERVER_PID" 2>/dev/null; then
      die "upstream server failed to start on 127.0.0.1:${CREDENTIALS_DEMO_PORT} (port in use?)"$'\n'"$(tail -n 5 "$CREDENTIALS_DEMO_OUT/server.log")"
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${CREDENTIALS_DEMO_PORT}/-/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  die "upstream server not ready on 127.0.0.1:${CREDENTIALS_DEMO_PORT} after 3s"
}

_server_stop() {
  kill "${CREDENTIALS_SERVER_PID:-}" 2>/dev/null || true
  wait "${CREDENTIALS_SERVER_PID:-}" 2>/dev/null || true
  trap - EXIT
}

# _selected_from <requests-log>
# Prints the distinct authenticated usernames seen in the log, "none" when every request was
# anonymous, or "error" when the log is missing or empty (the probe never reached the server).
_selected_from() {
  local users
  [[ -s "$1" ]] || { echo error; return 0; }
  users="$(awk -F'\t' '$3 != "-" { print $3 }' "$1" | sort -u | paste -sd'|' -)"
  echo "${users:-none}"
}

# _consumer <wget|oci|generic> <username> [attr=value | -attr ...]
# Emits one consumers entry at column 0. The username is the credential value and the password
# is always demo-password. "generic" is a Credentials/v1 entry (properties) on a Wget identity.
_consumer() {
  local kind="$1" user="$2" type cred_type arg key line attrs
  shift 2
  case "$kind" in
    wget)    type=Wget;        cred_type=WgetCredentials/v1 ;;
    oci)     type=OCIRegistry; cred_type=OCICredentials/v1 ;;
    generic) type=Wget;        cred_type=Credentials/v1 ;;
    *) die "unknown consumer kind: $kind" ;;
  esac
  attrs="type=$type
hostname=127.0.0.1
port=$CREDENTIALS_DEMO_PORT
scheme=http"
  for arg in "$@"; do
    case "$arg" in
      -*) key="${arg#-}"; attrs="$(grep -v "^${key}=" <<<"$attrs" || true)" ;;
      *)  key="${arg%%=*}"; attrs="$(grep -v "^${key}=" <<<"$attrs" || true)"$'\n'"$arg" ;;
    esac
  done
  printf -- '- identity:\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf "    %s: '%s'\n" "${line%%=*}" "${line#*=}"
  done <<<"$attrs"
  printf '  credentials:\n    - type: %s\n' "$cred_type"
  if [[ "$kind" == generic ]]; then
    printf "      properties:\n        username: '%s'\n        password: 'demo-password'\n" "$user"
  else
    printf "      username: '%s'\n      password: 'demo-password'\n" "$user"
  fi
}

_config_header() {
  printf 'type: generic.config.ocm.software/v1\nconfigurations:\n'
}

# _credentials_block <consumers-yaml>
_credentials_block() {
  printf '  - type: credentials.config.ocm.software\n    consumers:\n'
  # shellcheck disable=SC2001
  sed 's/^/      /' <<<"$1"
}

# _config <outfile> <consumers-yaml>...
# One credentials.config block per argument, in order, so later blocks override earlier ones.
_config() {
  local outfile="$1" block
  shift
  mkdir -p "$(dirname "$outfile")"
  {
    _config_header
    for block in "$@"; do
      _credentials_block "$block"
    done
  } > "$outfile"
}

# _config_nested <outfile> <consumers-yaml>
# A generic config nested inside a generic config. OCM ignores it and warns.
_config_nested() {
  mkdir -p "$(dirname "$1")"
  {
    _config_header
    printf '  - type: generic.config.ocm.software/v1\n    configurations:\n'
    _credentials_block "$2" | sed 's/^/    /'
  } > "$1"
}

# _probe_wget <dir> <urlpath> <config-file>...
# Downloads http://127.0.0.1:<port>/<urlpath> through a throwaway Wget/v1 input and prints the
# username the server saw. A "-" config reads that config from stdin.
_probe_wget() {
  local dir="$1" urlpath="$2" config input=/dev/null
  shift 2
  local config_args=()
  for config in "$@"; do
    config_args+=(--config "$config")
    [[ "$config" == - ]] && input=/dev/stdin
  done
  mkdir -p "$dir"
  cat > "$dir/constructor.yaml" <<EOF
name: github.com/lioramilbaum/credentials-probe
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: probe
    type: blob
    version: ${VERSION}
    input:
      type: Wget/v1
      url: http://127.0.0.1:${CREDENTIALS_DEMO_PORT}/${urlpath}
      mediaType: text/plain
EOF
  : > "$CREDENTIALS_DEMO_OUT/requests.log"
  "$OCM" add cv \
    --repository "ctf::$dir/ctf" \
    --constructor "$dir/constructor.yaml" \
    "${config_args[@]}" <"$input" >/dev/null 2>"$dir/stderr" || true
  cp "$CREDENTIALS_DEMO_OUT/requests.log" "$dir/requests.log"
  _selected_from "$dir/requests.log"
}

# _probe_oci <dir> <subpath> <config-file>
# Transfers the demo component to oci://127.0.0.1:<port>/<subpath> and prints the username the
# server saw. The OCI client only sends credentials after the 401 challenge.
_probe_oci() {
  local dir="$1" subpath="$2" config="$3"
  mkdir -p "$dir"
  : > "$CREDENTIALS_DEMO_OUT/requests.log"
  "$OCM" transfer cv --config "$config" "$(_cred_ref)" \
    "oci::http://127.0.0.1:${CREDENTIALS_DEMO_PORT}/${subpath}" </dev/null >/dev/null 2>"$dir/stderr" || true
  cp "$CREDENTIALS_DEMO_OUT/requests.log" "$dir/requests.log"
  _selected_from "$dir/requests.log"
}

# The Wget probes need these files; team-a/report.txt and team-a/nested/report.txt are distinct paths.
_upstream_files() {
  local root="$CREDENTIALS_DEMO_OUT/upstream"
  mkdir -p "$root/team-a/nested" "$root/team-b"
  printf 'team-a report\n' > "$root/team-a/report.txt"
  printf 'team-a nested report\n' > "$root/team-a/nested/report.txt"
  printf 'team-b report\n' > "$root/team-b/report.txt"
}

_build() {
  mkdir -p "$CREDENTIALS_DEMO_OUT/stage"
  cp "$CREDENTIALS_DEMO_CONSTRUCTOR" "$CREDENTIALS_DEMO_OUT/stage/component-constructor.yaml"
  cp "$CREDENTIALS_OCI_LAYOUT" "$CREDENTIALS_DEMO_OUT/stage/hello-oci-multiarch.oci.tar"
  rm -rf "${CREDENTIALS_DEMO_CTF:?}"
  _empty_config
  "$OCM" add cv \
    --repository "ctf::$CREDENTIALS_DEMO_CTF" \
    --constructor "$CREDENTIALS_DEMO_OUT/stage/component-constructor.yaml" \
    --config "$CREDENTIALS_DEMO_OUT/empty.ocmconfig" </dev/null >/dev/null
}

_show() {
  local types t ex f
  types="$("$OCM" get types credentials)"
  for t in OCICredentials/v1 WgetCredentials/v1 HelmHTTPCredentials/v1 GitHubCredentials/v1 \
    GitCredentials/v1 S3Credentials/v1 RSACredentials/v1 GPGCredentials/v1alpha1; do
    grep -qF "$t" <<<"$types" || die "credential type not registered in this OCM binary: $t"
  done

  printf 'identity\tOCIRegistry\thostname,scheme,port,path\tOCICredentials/v1\n'
  printf 'identity\tWget\thostname,scheme,port,path\tWgetCredentials/v1\n'
  printf 'identity\tHelmChartRepository\thostname,scheme,port,path\tHelmHTTPCredentials/v1\n'
  printf 'identity\tGitHubRepository\thostname,scheme,port,path\tGitHubCredentials/v1\n'
  printf 'identity\tGit\thostname,scheme,port,path\tGitCredentials/v1\n'
  printf 'identity\tS3\thostname,scheme,port,path\tS3Credentials/v1\n'
  printf 'identity\tRSA/v1alpha1\talgorithm,signature\tRSACredentials/v1\n'
  printf 'identity\tGPG/v1alpha1\tsignature\tGPGCredentials/v1alpha1\n'

  ex="$CREDENTIALS_DEMO_OUT/examples"
  mkdir -p "$ex"
  _config "$ex/oci.ocmconfig" "$(_consumer oci team-a "path=team-a")"
  _config "$ex/wget.ocmconfig" "$(_consumer wget team-a "path=team-a/report.txt")"
  _config "$ex/generic-flat.ocmconfig" \
    "$(_consumer wget team-a "path=team-a/*")" \
    "$(_consumer oci team-b "path=team-b")"
  for f in oci wget generic-flat; do
    printf 'parsed\t%s\t%s\n' "$ex/$f.ocmconfig" \
      "$("$OCM" get config --config "$ex/$f.ocmconfig" -o json \
        | jq -r '[.configurations[] | select(.type=="credentials.config.ocm.software") | .consumers[].identities[].type] | join(",")')"
  done
}

# _match_row <rule> <urlpath> <consumers-yaml>
_match_row() {
  local rule="$1" urlpath="$2" dir="$CREDENTIALS_DEMO_OUT/match/$1" selected
  _upstream_files
  _config "$dir/config.ocmconfig" "$3"
  selected="$(_probe_wget "$dir" "$urlpath" "$dir/config.ocmconfig")"
  printf '%s\tWget\t%s\t%s\n' "$rule" "$urlpath" "$selected"
}

_match() {
  _match_row exact-over-wildcard team-a/report.txt "$(_consumer wget wildcard "path=team-a/*")
$(_consumer wget exact "path=team-a/report.txt")"
  _match_row exact-over-wildcard-reversed team-a/report.txt "$(_consumer wget exact "path=team-a/report.txt")
$(_consumer wget wildcard "path=team-a/*")"
  _match_row wildcard-subpath team-a/report.txt "$(_consumer wget team-a-wild "path=team-a/*")"
  _match_row star-not-across-slash team-a/nested/report.txt "$(_consumer wget team-a-wild "path=team-a/*")"
  _match_row star-per-segment team-a/nested/report.txt "$(_consumer wget team-a-nested "path=team-a/*/*")"
  _match_row no-path-matches-all team-a/nested/report.txt "$(_consumer wget host)"
  _match_row hostname-missing team-a/report.txt "$(_consumer wget no-host -hostname)"
  _match_row hostname-not-resolved team-a/report.txt "$(_consumer wget localhost hostname=localhost)"
  _match_row port-omitted team-a/report.txt "$(_consumer wget no-port -port)"
  _match_row port-mismatch team-a/report.txt "$(_consumer wget other-port port=18442)"
  _match_row scheme-omitted team-a/report.txt "$(_consumer wget no-scheme -scheme)"
  _match_row scheme-mismatch team-a/report.txt "$(_consumer wget https-mismatch scheme=https)"
  _match_row type-alias team-a/report.txt "$(_consumer wget http-alias type=HTTP)"
}

# _chain_row <case> <urlpath> <config-file>...
_chain_row() {
  local case="$1" urlpath="$2" selected
  shift 2
  _upstream_files
  selected="$(_probe_wget "$CREDENTIALS_DEMO_OUT/chain/$case" "$urlpath" "$@")"
  printf '%s\t%s\t%s\n' "$case" "$urlpath" "$selected"
}

_chain() {
  local base="$CREDENTIALS_DEMO_OUT/chain" cfg="$CREDENTIALS_DEMO_OUT/chain/configs"
  local a b b2 flat nested stdin_selected
  rm -rf "$base"
  a="$cfg/a.ocmconfig"
  b="$cfg/b.ocmconfig"
  b2="$cfg/b-override.ocmconfig"
  flat="$cfg/flat.ocmconfig"
  nested="$cfg/nested.ocmconfig"
  _config "$a" "$(_consumer wget file-a "path=team-a/*")"
  _config "$b" "$(_consumer wget file-b "path=team-b/*")"
  _config "$b2" "$(_consumer wget file-b-override "path=team-a/*")"
  _config "$flat" "$(_consumer wget flat-a "path=team-a")" "$(_consumer wget flat-b "path=team-b")"
  _config_nested "$nested" "$(_consumer wget nested-result "path=result")"

  _chain_row two-files/team-a team-a/report.txt "$a" "$b"
  _chain_row two-files/team-b team-b/report.txt "$a" "$b"
  _chain_row later-file-wins/forward team-a/report.txt "$a" "$b2"
  _chain_row later-file-wins/reversed team-a/report.txt "$b2" "$a"
  # One config arrives on stdin; OCM reads "-" once, so the second config is a file.
  _upstream_files
  stdin_selected="$(_probe_wget "$base/stdin" team-b/report.txt - "$b" < "$a")"
  printf 'stdin\tteam-b/report.txt\t%s\n' "$stdin_selected"
  _chain_row generic-flat/team-a team-a "$flat"
  _chain_row generic-flat/team-b team-b "$flat"
  _upstream_files
  printf 'generic-nested/result\tresult\t%s\n' "$(_probe_wget "$base/generic-nested" result "$nested")"

  printf 'merged\t%s\n' "$("$OCM" get config --config "$a" --config "$b" -o json \
    | jq -r '[.configurations[] | select(.type=="credentials.config.ocm.software") | .consumers[].credentials[].username] | unique | join(",")')"
}

# _scenario <name> <probe-type> <request> <candidates> <consumers-yaml> [dir]
_scenario() {
  local name="$1" kind="$2" request="$3" candidates="$4" consumers="$5"
  local dir="${6:-$CREDENTIALS_DEMO_OUT/scenarios/$1}" selected
  _config "$dir/config.ocmconfig" "$consumers"
  _upstream_files
  if [[ "$kind" == OCIRegistry ]]; then
    selected="$(_probe_oci "$dir" "$request" "$dir/config.ocmconfig")"
  else
    selected="$(_probe_wget "$dir" "$request" "$dir/config.ocmconfig")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$request" "$candidates" "$selected"
}

_scenarios() {
  local i
  [[ -f "$CREDENTIALS_DEMO_CTF/artifact-index.json" ]] || _build
  rm -rf "$CREDENTIALS_DEMO_OUT/scenarios"

  _scenario oci-host OCIRegistry team-a host "$(_consumer oci host)"
  _scenario oci-path-exact OCIRegistry team-a exact "$(_consumer oci exact "path=team-a")"
  _scenario oci-path-glob OCIRegistry team-a glob "$(_consumer oci glob "path=team-*")"
  _scenario oci-path-other OCIRegistry team-a other "$(_consumer oci other "path=team-b")"
  _scenario oci-star-not-across-slash OCIRegistry team-a/nested star "$(_consumer oci star "path=*")"
  _scenario oci-exact-over-glob OCIRegistry team-a "exact|glob" "$(_consumer oci glob "path=team-*")
$(_consumer oci exact "path=team-a")"
  _scenario type-mismatch-wget OCIRegistry team-a wget-user "$(_consumer wget wget-user)"
  _scenario type-mismatch-oci Wget team-a/report.txt oci-user "$(_consumer oci oci-user)"
  _scenario duplicate-identity OCIRegistry team-a "first|second" "$(_consumer oci first)
$(_consumer oci second)"
  _scenario typed-over-generic Wget team-a/report.txt "typed|direct" "$(_consumer wget typed)
$(_consumer generic direct)"
  _scenario generic-credentials Wget team-a/report.txt generic "$(_consumer generic generic)"
  for i in $(seq 1 10); do
    _scenario overlap-wildcards Wget team-a/report.txt "host|team-a-wild" \
      "$(_consumer wget host)
$(_consumer wget team-a-wild "path=team-a/*")" "$CREDENTIALS_DEMO_OUT/scenarios/overlap-wildcards/$i"
  done
}

mkdir -p "$CREDENTIALS_DEMO_OUT"
_empty_config

case "${1:-}" in
  build)     _build ;;
  show)      _show ;;
  match)     _server_start; _match ;;
  chain)     _server_start; _chain ;;
  scenarios) _server_start; _scenarios ;;
  *)         _build; echo; _show; echo; _server_start; _match ;;
esac
