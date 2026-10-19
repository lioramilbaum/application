#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq curl python3

GITHUB_DEMO_PORT="${GITHUB_DEMO_PORT:-18451}"
GITHUB_DEMO_OUT="${GITHUB_DEMO_OUT:-$BUILD_DIR/github}"
GITHUB_DEMO_CTF="${GITHUB_DEMO_CTF:-$BUILD_DIR/github-ctf}"
GITHUB_DEMO_REPO_URL="http://127.0.0.1:${GITHUB_DEMO_PORT}/lioramilbaum/hello-world"

# Fixed commit SHAs used by the emulator
_COMMIT1="1111111111111111111111111111111111111111"
_COMMIT2="2222222222222222222222222222222222222222"

_server_pid=""

_server_stop() {
  if [[ -n "${_server_pid:-}" ]]; then
    kill "$_server_pid" 2>/dev/null || true
    # Wait so a restart on the same port does not race the old listener.
    wait "$_server_pid" 2>/dev/null || true
  fi
}

_server_start() {
  local refs_file="$GITHUB_DEMO_OUT/refs"
  printf '%s %s\n' refs/heads/main "$_COMMIT1" > "$refs_file"

  python3 -I "$ROOT/scripts/github-api-server.py" \
    --port "$GITHUB_DEMO_PORT" \
    --refs-file "$refs_file" \
    --commits-dir "$ROOT/components/github/upstream" \
    --owner lioramilbaum --repo hello-world \
    --log "$GITHUB_DEMO_OUT/requests.log" &
  _server_pid="$!"
  trap _server_stop EXIT

  # --max-time: a foreign listener on the port accepts but never answers.
  local _
  for _ in $(seq 1 40); do
    kill -0 "$_server_pid" 2>/dev/null || break
    curl -fsS --max-time 2 "http://127.0.0.1:${GITHUB_DEMO_PORT}/-/ready" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  die "GitHub API emulator failed to start on port ${GITHUB_DEMO_PORT} (port in use?)"
}

_component_ref() {
  echo "ctf::${GITHUB_DEMO_CTF}//github.com/lioramilbaum/github-demo:${VERSION}"
}

_build() {
  mkdir -p "$GITHUB_DEMO_OUT"
  _server_start
  rm -rf "${GITHUB_DEMO_CTF:?}"
  GITHUB_DEMO_REPO_URL="$GITHUB_DEMO_REPO_URL" \
    "$OCM" add cv --repository "ctf::$GITHUB_DEMO_CTF" \
      --constructor "$ROOT/components/github/component-constructor.yaml" </dev/null >/dev/null

  local commit digest
  commit="$("$OCM" get cv "$(_component_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[0].access.commit')"
  [[ "$commit" == "$_COMMIT1" ]] || die "expected commit $_COMMIT1 but got $commit"

  local archive
  archive="$GITHUB_DEMO_OUT/check.tar.gz"
  curl -fsS -L "http://127.0.0.1:${GITHUB_DEMO_PORT}/api/v3/repos/lioramilbaum/hello-world/tarball/${_COMMIT1}" \
    -o "$archive"
  digest="$(sha256 "$archive")"
  local stored
  stored="$("$OCM" get cv "$(_component_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[0].digest.value')"
  [[ "$digest" == "$stored" ]] || die "digest mismatch: stored=$stored computed=$digest"
  rm -f "$archive"
  # Stop here so a later server start in the same run does not find the port taken.
  _server_stop
  _server_pid=""
}

_sign() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null >/dev/null
}

_verify() {
  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null
}

_download() {
  local out="$GITHUB_DEMO_OUT/archive.tgz"
  rm -f "$out"
  if ! "$OCM" download resource \
      --identity "name=hello-world-repo-archive" \
      --output "$out" \
      "$(_component_ref)" </dev/null >/dev/null; then
    rm -f "$out"
    die "download failed"
  fi
  tar -tzf "$out" | head -5
}

_scenarios() {
  local refs_file="$GITHUB_DEMO_OUT/refs"
  local log_file="$GITHUB_DEMO_OUT/requests.log"

  # pinned
  local out="$GITHUB_DEMO_OUT/scenario-archive.tgz"
  rm -f "$out"
  "$OCM" download resource --identity "name=hello-world-repo-archive" \
    --output "$out" "$(_component_ref)" </dev/null >/dev/null 2>&1
  printf 'pinned\tok\t%s\n' "$(sha256 "$out")"
  rm -f "$out"

  # branch-moved
  printf '%s %s\n' refs/heads/main "$_COMMIT2" > "$refs_file"
  rm -f "$log_file"
  rm -f "$out"
  "$OCM" download resource --identity "name=hello-world-repo-archive" \
    --output "$out" "$(_component_ref)" </dev/null >/dev/null 2>&1 || true
  local fetched_sha
  fetched_sha="$(grep tarball "$log_file" 2>/dev/null | grep -o '[a-f0-9]\{40\}' | head -1 || true)"
  if [[ "$fetched_sha" == "$_COMMIT1" ]]; then
    printf 'branch-moved\tpinned-commit-kept\t%s\n' "$fetched_sha"
  else
    printf 'branch-moved\tunexpected-sha\t%s\n' "$fetched_sha"
  fi
  printf '%s %s\n' refs/heads/main "$_COMMIT1" > "$refs_file"
  rm -f "$out"

  # archive-rewritten: restart server with rewrite
  _server_stop
  python3 -I "$ROOT/scripts/github-api-server.py" \
    --port "$GITHUB_DEMO_PORT" \
    --refs-file "$refs_file" \
    --commits-dir "$ROOT/components/github/upstream" \
    --owner lioramilbaum --repo hello-world \
    --log "$log_file" \
    --rewrite-sha "$_COMMIT1" &
  _server_pid="$!"
  # --max-time: a foreign listener on the port accepts but never answers.
  local _ ready=0
  for _ in $(seq 1 40); do
    kill -0 "$_server_pid" 2>/dev/null || break
    curl -fsS --max-time 2 "http://127.0.0.1:${GITHUB_DEMO_PORT}/-/ready" >/dev/null 2>&1 && { ready=1; break; }
    sleep 0.25
  done
  [[ "$ready" -eq 1 ]] || die "GitHub API emulator failed to restart on port ${GITHUB_DEMO_PORT} (port in use?)"
  local err
  err="$("$OCM" download resource --identity "name=hello-world-repo-archive" \
    --output "$out" "$(_component_ref)" </dev/null 2>&1 || true)"
  rm -f "$out"
  if echo "$err" | grep -q "digest mismatch"; then
    printf 'archive-rewritten\tdigest-mismatch\tok\n'
  else
    printf 'archive-rewritten\tunexpected\t%s\n' "$err"
  fi
  _server_stop; _server_pid=""

  # api-down
  err="$("$OCM" download resource --identity "name=hello-world-repo-archive" \
    --output "$out" "$(_component_ref)" </dev/null 2>&1 || true)"
  rm -f "$out"
  if echo "$err" | grep -qE "connection refused|dial"; then
    printf 'api-down\tconnection-refused\tok\n'
  else
    printf 'api-down\tunexpected\t%s\n' "$err"
  fi

  # copied: transfer inlines archive, works offline
  local copied_ctf="$GITHUB_DEMO_OUT/copied-ctf"
  rm -rf "${copied_ctf:?}"
  _server_start
  "$OCM" transfer cv "$(_component_ref)" "ctf::$copied_ctf" \
    --config "$ROOT/components/github/transfer.ocmconfig" </dev/null >/dev/null
  _server_stop; _server_pid=""
  local access_type
  access_type="$("$OCM" get cv "ctf::${copied_ctf}//github.com/lioramilbaum/github-demo:${VERSION}" \
    -o json </dev/null | jq -r '.[0].component.resources[0].access.type')"
  "$OCM" download resource --identity "name=hello-world-repo-archive" \
    --output "$out" "ctf::${copied_ctf}//github.com/lioramilbaum/github-demo:${VERSION}" </dev/null >/dev/null
  printf 'copied\t%s\tok\n' "$access_type"
  rm -f "$out"
}

_show() {
  "$OCM" get cv "$(_component_ref)" -o json </dev/null | jq -r '
    .[0].component.resources[0] |
    ["type", .access.type],
    ["repoUrl", .access.repoUrl],
    ["ref", .access.ref],
    ["commit", .access.commit],
    ["digest", .digest.value[0:16]]
    | @tsv'
}

_online() {
  [[ "${GITHUB_DEMO_ONLINE:-0}" == "1" ]] \
    || { echo "skip: set GITHUB_DEMO_ONLINE=1 to fetch from github.com" >&2; exit 0; }

  local online_ctf="$GITHUB_DEMO_OUT/online-ctf"
  rm -rf "${online_ctf:?}"
  "$OCM" add cv --repository "ctf::$online_ctf" \
    --constructor "$ROOT/components/github/online-constructor.yaml" </dev/null >/dev/null

  "$OCM" download resource \
    --identity "name=ocm-examples-archive" \
    --output "$GITHUB_DEMO_OUT/ocm-examples.tar.gz" \
    "ctf::${online_ctf}//github.com/lioramilbaum/github-demo-online:${VERSION}" </dev/null >/dev/null
  echo "ocm-examples top dir:"
  tar -tzf "$GITHUB_DEMO_OUT/ocm-examples.tar.gz" | sed -n 1p

  "$OCM" download resource \
    --identity "name=ocm-helm-chart-release-asset" \
    --output "$GITHUB_DEMO_OUT/chart.tgz" \
    "ctf::${online_ctf}//github.com/lioramilbaum/github-demo-online:${VERSION}" </dev/null >/dev/null
  local magic
  magic="$(od -A n -t x1 -N 3 "$GITHUB_DEMO_OUT/chart.tgz" | tr -d ' \n')"
  if [[ "$magic" == "1f8b08" ]]; then
    echo "release asset: valid gzip"
  else
    echo "release asset: unexpected magic $magic"
  fi
}

mkdir -p "$GITHUB_DEMO_OUT"

case "${1:-}" in
  build)     _build ;;
  sign)      _sign ;;
  verify)    _verify ;;
  download)  _server_start; _download ;;
  scenarios) _server_start; _scenarios ;;
  show)      _show ;;
  online)    _online ;;
  *)         _build; _sign; _verify; echo ""; _show; echo ""; _server_start; _download; echo ""; _scenarios ;;
esac
