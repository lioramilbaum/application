#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" git jq tar diff

# Gate: Git/v1 input and access first ship in OCM 0.19.0.
_ocm_ver="$("$OCM" version 2>/dev/null | sed -n 's/^[[:space:]]*Version:[[:space:]]*//p' | head -n1 || true)"
_ocm_ver="${_ocm_ver#v}"
_ocm_ver="${_ocm_ver%%-*}"
IFS=. read -r _ocm_major _ocm_minor _ <<<"$_ocm_ver"
# Allow source builds (OCM built from main reports "(devel)")
if [[ "$_ocm_ver" != *"devel"* ]] && { [[ ! "${_ocm_major:-}" =~ ^[0-9]+$ || ! "${_ocm_minor:-}" =~ ^[0-9]+$ ]] \
  || (( _ocm_major == 0 && _ocm_minor < 19 )); }; then
  die "scripts/git.sh requires OCM CLI >= 0.19.0 (found: ${_ocm_ver:-unknown}) — Git/v1 input and access first ship in 0.19.0"
fi

GIT_COMPONENT="github.com/lioramilbaum/git-demo"
GIT_DEMO_CTF="${GIT_DEMO_CTF:-$BUILD_DIR/git-ctf}"
GIT_DEMO_OUT="${GIT_DEMO_OUT:-$BUILD_DIR/git}"
GIT_DEMO_CONSTRUCTOR="${GIT_DEMO_CONSTRUCTOR:-$ROOT/components/git/component-constructor.yaml}"
GIT_DEMO_REF="${GIT_DEMO_REF:-refs/heads/main}"
UPSTREAM_SRC="$ROOT/components/git/upstream"
UPSTREAM="$GIT_DEMO_OUT/upstream.git"
UPSTREAM_TAG="v0.1.0"
SOURCE="hello-world-source"
SNAPSHOT="hello-world-source-snapshot"
TRACKED="hello-world-source-tracked"
COMMIT_LABEL="git.lioramilbaum.github.com/commit"

# Bring your own repository: set both or neither.
OWN_REPO=0
if [[ -n "${GIT_DEMO_REPO:-}" || -n "${GIT_DEMO_COMMIT:-}" ]]; then
  [[ -n "${GIT_DEMO_REPO:-}" && -n "${GIT_DEMO_COMMIT:-}" ]] || die "set both GIT_DEMO_REPO and GIT_DEMO_COMMIT, or neither"
  if [[ "$GIT_DEMO_COMMIT" =~ ^[0-9a-f]{64}$ ]]; then
    die "GIT_DEMO_COMMIT is a SHA-256 object name; OCM 0.19.1 reads SHA-1 repositories only"
  fi
  [[ "$GIT_DEMO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "GIT_DEMO_COMMIT must be a 40-char git commit SHA (got: '$GIT_DEMO_COMMIT')"
  OWN_REPO=1
else
  GIT_DEMO_REPO="file://$UPSTREAM"
fi
export ROOT VERSION GIT_DEMO_REPO GIT_DEMO_REF

# _git_at <date> <git args...>: fixed identity and date, no user or system git config.
_git_at() {
  local date="$1"
  shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME="OCM Demo" GIT_AUTHOR_EMAIL="demo@lioramilbaum.github.com" GIT_AUTHOR_DATE="$date" \
    GIT_COMMITTER_NAME="OCM Demo" GIT_COMMITTER_EMAIL="demo@lioramilbaum.github.com" GIT_COMMITTER_DATE="$date" \
    git "$@"
}

_git() { _git_at 2026-01-01T00:00:00Z "$@"; }

_ref() {
  echo "ctf::${1:-$GIT_DEMO_CTF}//${GIT_COMPONENT}:${VERSION}"
}

# Recreates the demo repository; fixed content, identity and date give the same commit every run.
_upstream() {
  local work="$GIT_DEMO_OUT/upstream-work"
  rm -rf "${UPSTREAM:?}" "${work:?}"
  mkdir -p "$GIT_DEMO_OUT"
  _git init -q --object-format=sha1 -b main "$work"
  cp -R "$UPSTREAM_SRC/." "$work/"
  _git -C "$work" add -A
  _git -C "$work" update-index --chmod=+x build.sh
  _git -C "$work" commit -q -m "hello-world 0.1.0"
  _git -C "$work" tag "$UPSTREAM_TAG"
  _git clone -q --bare "$work" "$UPSTREAM"
  rm -rf "${work:?}"
}

_resolve_commit() {
  if (( OWN_REPO )); then return 0; fi
  [[ -d "$UPSTREAM" ]] || _upstream
  GIT_DEMO_COMMIT="$(_git --git-dir "$UPSTREAM" rev-parse "${UPSTREAM_TAG}^{commit}")"
  export GIT_DEMO_COMMIT
}

# _build_into <ctf>
_build_into() {
  rm -rf "${1:?}"
  (( OWN_REPO )) || _upstream
  _resolve_commit
  # shellcheck disable=SC2086
  "$OCM" add cv \
    --repository "ctf::$1" \
    --constructor "$GIT_DEMO_CONSTRUCTOR" \
    ${OCM_ADD_FLAGS:-} < /dev/null
}

_sign_ctf() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default "$(_ref "$1")" < /dev/null
}

_verify_ctf() {
  "$OCM" verify cv --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" --signature default \
    "$(_ref "$1")" < /dev/null
}

_cv_json() {
  "$OCM" get cv "$(_ref "${1:-}")" -o json < /dev/null
}

# _fetch <ctf> <resource> <outfile> <stderr-file>
_fetch() {
  "$OCM" download resource --identity "name=$2" --output "$3" "$(_ref "$1")" < /dev/null >/dev/null 2>"$4"
}

# _classify <stderr-file>
_classify() {
  local text
  text="$(cat "$1" 2>/dev/null || true)"
  # OCM 0.19.1
  if grep -q 'git archive digest mismatch' <<<"$text"; then
    echo archive-mismatch
  # OCM 0.19.1 — go-git transport when the pinned commit is not in the repository
  elif grep -q 'server sent no packfile' <<<"$text"; then
    echo missing-commit
  # OCM 0.19.1
  elif grep -q 'repository not found' <<<"$text"; then
    echo repository-not-found
  # OCM 0.19.1
  elif grep -q 'digest mismatch' <<<"$text"; then
    echo digest-mismatch
  else
    echo error
  fi
}

_download() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify_ctf "$GIT_DEMO_CTF" >/dev/null
  local stage cv_json r want reason
  stage="$(mktemp -d "$GIT_DEMO_OUT/.download.XXXXXX")"
  cv_json="$(_cv_json)"
  for r in "$SNAPSHOT" "$TRACKED"; do
    if ! _fetch "$GIT_DEMO_CTF" "$r" "$stage/$r.tgz" "$stage/$r.stderr"; then
      cat "$stage/$r.stderr" >&2
      reason="$(_classify "$stage/$r.stderr")"
      rm -rf "$stage"
      die "$r: download failed ($reason)"
    fi
    want="$(jq -r --arg r "$r" '.[0].component.resources[] | select(.name==$r) | .digest.value' <<<"$cv_json")"
    if [[ "$(sha256 "$stage/$r.tgz")" != "$want" ]]; then
      rm -rf "$stage"
      die "$r: archive does not match the signed digest"
    fi
    rm -f "$stage/$r.stderr"
  done
  rm -rf "$GIT_DEMO_OUT/download"
  mv "$stage" "$GIT_DEMO_OUT/download"
  echo "$GIT_DEMO_OUT/download/$SNAPSHOT.tgz"
  echo "$GIT_DEMO_OUT/download/$TRACKED.tgz"
}

_audit() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify_ctf "$GIT_DEMO_CTF" >/dev/null
  local cv_json commit digest repo
  cv_json="$(_cv_json)"
  commit="$(jq -r --arg r "$SNAPSHOT" --arg l "$COMMIT_LABEL" \
    '.[0].component.resources[] | select(.name==$r) | .labels[]? | select(.name==$l and .signing==true) | .value' <<<"$cv_json")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$SNAPSHOT has no signed $COMMIT_LABEL label"
  digest="$(jq -r --arg r "$SNAPSHOT" '.[0].component.resources[] | select(.name==$r) | .digest.value' <<<"$cv_json")"
  repo="$(jq -r --arg s "$SOURCE" '.[0].component.sources[] | select(.name==$s) | .access.repository' <<<"$cv_json")"

  local AUDIT_DIR
  AUDIT_DIR="$(mktemp -d "$GIT_DEMO_OUT/.audit.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$AUDIT_DIR'" EXIT
  _fetch "$GIT_DEMO_CTF" "$SNAPSHOT" "$AUDIT_DIR/snapshot.tgz" "$AUDIT_DIR/fetch.stderr" \
    || die "$SNAPSHOT: download failed ($(_classify "$AUDIT_DIR/fetch.stderr"))"
  [[ "$(sha256 "$AUDIT_DIR/snapshot.tgz")" == "$digest" ]] || die "$SNAPSHOT: archive does not match the signed digest"
  mkdir -p "$AUDIT_DIR/snapshot" "$AUDIT_DIR/commit"
  tar -xzf "$AUDIT_DIR/snapshot.tgz" -C "$AUDIT_DIR/snapshot"
  _git init -q --bare --object-format=sha1 "$AUDIT_DIR/repo.git"
  _git --git-dir "$AUDIT_DIR/repo.git" fetch -q "$repo" "$commit" 2>/dev/null || die "commit $commit not found in $repo"
  _git --git-dir "$AUDIT_DIR/repo.git" archive "$commit" | tar -x -C "$AUDIT_DIR/commit"
  diff -r --exclude='.git' "$AUDIT_DIR/snapshot" "$AUDIT_DIR/commit" >/dev/null || die "snapshot does not match commit $commit"
  printf 'audit\t%s\t%s\tmatch\n' "$commit" "$digest"
}

# _mutate <scenario> <workdir>
_mutate() {
  local work="$2/work-$1" commit
  case "$1" in
    baseline) ;;
    branch-moved)
      _git clone -q "$UPSTREAM" "$work"
      printf '<p>main moved on</p>\n' >> "$work/index.html"
      _git_at 2026-01-02T00:00:00Z -C "$work" commit -q -am "move main"
      _git -C "$work" push -q origin main
      ;;
    history-rewritten)
      commit="$(_git --git-dir "$UPSTREAM" rev-parse "${UPSTREAM_TAG}^{commit}")"
      _git clone -q "$UPSTREAM" "$work"
      _git -C "$work" checkout -q --orphan rewritten
      printf '<h1>Rewritten</h1>\n' > "$work/index.html"
      _git_at 2026-01-03T00:00:00Z -C "$work" commit -q -am "rewrite history"
      _git -C "$work" push -q -f origin rewritten:main
      _git --git-dir "$UPSTREAM" tag -d "$UPSTREAM_TAG" >/dev/null
      _git --git-dir "$UPSTREAM" reflog expire --expire=now --all
      _git --git-dir "$UPSTREAM" gc -q --prune=now
      ! _git --git-dir "$UPSTREAM" cat-file -e "${commit}^{commit}" 2>/dev/null \
        || die "history-rewritten: $commit is still in the repository"
      ;;
    upstream-deleted) rm -rf "${UPSTREAM:?}" ;;
    *) die "unknown scenario: $1" ;;
  esac
}

_scenarios() {
  (( ! OWN_REPO )) || die "scenarios use the generated demo repository; unset GIT_DEMO_REPO and GIT_DEMO_COMMIT"
  local dir="$GIT_DEMO_OUT/scenarios" ctf name verify snapshot tracked reason
  rm -rf "${dir:?}"
  mkdir -p "$dir"
  ctf="$dir/ctf"
  _build_into "$ctf" >/dev/null 2>"$dir/build.stderr" || { cat "$dir/build.stderr" >&2; die "scenario build failed"; }
  _sign_ctf "$ctf" >/dev/null
  for name in baseline branch-moved history-rewritten upstream-deleted; do
    _upstream
    _mutate "$name" "$dir"
    verify=ok snapshot=ok tracked=ok reason=-
    if ! _verify_ctf "$ctf" >/dev/null 2>"$dir/$name.verify.stderr"; then
      verify=fail reason="$(_classify "$dir/$name.verify.stderr")"
    fi
    if ! _fetch "$ctf" "$SNAPSHOT" "$dir/$name-snapshot.tgz" "$dir/$name.snapshot.stderr"; then
      snapshot=fail
      [[ "$reason" != - ]] || reason="$(_classify "$dir/$name.snapshot.stderr")"
    fi
    if ! _fetch "$ctf" "$TRACKED" "$dir/$name-tracked.tgz" "$dir/$name.tracked.stderr"; then
      tracked=fail
      [[ "$reason" != - ]] || reason="$(_classify "$dir/$name.tracked.stderr")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$verify" "$snapshot" "$tracked" "$reason"
  done
  _upstream
}

_transfer() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify_ctf "$GIT_DEMO_CTF" >/dev/null
  local target="$GIT_DEMO_OUT/transfer-ctf"
  rm -rf "${target:?}"
  "$OCM" transfer cv --copy-resources "$(_ref)" "ctf::$target" < /dev/null >/dev/null
  _cv_json "$target" | jq -r '.[0].component
    | (.sources[] | ["source", .name, .access.type]),
      (.resources[] | ["resource", .name, .access.type])
    | @tsv'
}

_show() {
  _cv_json | jq -r --arg l "$COMMIT_LABEL" '.[0].component
    | (.sources[] | ["source", .name, .access.type, .access.commit, "no", "-"]),
      (.resources[]
        | ((.labels // []) | map(select(.name==$l and .signing==true)) | first) as $label
        | ["resource", .name, .access.type,
           (.access.commit // $label.value // "-"),
           (if $label then "yes" else "no" end),
           .digest.value])
    | @tsv'
}

mkdir -p "$GIT_DEMO_OUT"

case "${1:-}" in
  upstream)
    (( ! OWN_REPO )) || die "upstream creates the demo repository; unset GIT_DEMO_REPO and GIT_DEMO_COMMIT"
    _upstream
    _git --git-dir "$UPSTREAM" rev-parse "${UPSTREAM_TAG}^{commit}"
    ;;
  build)     _build_into "$GIT_DEMO_CTF" ;;
  sign)      _sign_ctf "$GIT_DEMO_CTF" ;;
  verify)    _verify_ctf "$GIT_DEMO_CTF" ;;
  download)  _download ;;
  audit)     _audit ;;
  scenarios) _scenarios ;;
  transfer)  _transfer ;;
  show)      _show ;;
  *)         _build_into "$GIT_DEMO_CTF"; _sign_ctf "$GIT_DEMO_CTF"; _verify_ctf "$GIT_DEMO_CTF"; SKIP_VERIFY=1 _audit; echo ""; _show ;;
esac
