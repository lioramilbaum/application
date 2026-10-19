#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq

GRAPH_DEMO_OUT="${GRAPH_DEMO_OUT:-$BUILD_DIR/graph}"
GRAPH_BASE_CTF="$GRAPH_DEMO_OUT/base-ctf"
GRAPH_APPS_CTF="$GRAPH_DEMO_OUT/apps-ctf"
GRAPH_PLATFORM_CTF="$GRAPH_DEMO_OUT/platform-ctf"
GRAPH_FLAT_CTF="$GRAPH_DEMO_OUT/flat-ctf"
GRAPH_RELEASE_CTF="$GRAPH_DEMO_OUT/release-ctf"

GRAPH_PLATFORM="github.com/lioramilbaum/graph/platform"

GRAPH_RUNTIME_TEXT="${GRAPH_RUNTIME_TEXT:-runtime v${VERSION}}"

_platform_ref() {
  echo "ctf::${GRAPH_PLATFORM_CTF}//${GRAPH_PLATFORM}:${VERSION}"
}

# _resolvers <outfile> <base-ctf> <apps-ctf>
# Order matters: the specific runtime pattern must precede the wildcard.
_resolvers() {
  cat > "$1" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      - repository:
          type: CommonTransportFormat/v1
          filePath: $2
          accessMode: readonly
        componentNamePattern: github.com/lioramilbaum/graph/runtime
      - repository:
          type: CommonTransportFormat/v1
          filePath: $3
          accessMode: readonly
        componentNamePattern: github.com/lioramilbaum/graph/*
EOF
}

_build() {
  rm -rf "${GRAPH_BASE_CTF:?}" "${GRAPH_APPS_CTF:?}" "${GRAPH_PLATFORM_CTF:?}" \
         "${GRAPH_FLAT_CTF:?}" "${GRAPH_RELEASE_CTF:?}"
  mkdir -p "$GRAPH_DEMO_OUT"

  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"
  _resolvers "$config" "$GRAPH_BASE_CTF" "$GRAPH_APPS_CTF"

  GRAPH_RUNTIME_TEXT="$GRAPH_RUNTIME_TEXT" \
    "$OCM" add cv --repository "ctf::$GRAPH_BASE_CTF" \
      --constructor "$ROOT/components/graph/runtime.yaml" </dev/null >/dev/null

  "$OCM" add cv --repository "ctf::$GRAPH_APPS_CTF" \
    --constructor "$ROOT/components/graph/apps.yaml" \
    --config "$config" \
    --external-component-version-copy-policy skip </dev/null >/dev/null

  "$OCM" add cv --repository "ctf::$GRAPH_PLATFORM_CTF" \
    --constructor "$ROOT/components/graph/platform.yaml" \
    --config "$config" \
    --external-component-version-copy-policy skip </dev/null >/dev/null

  local refs
  refs="$("$OCM" get cv "$(_platform_ref)" -o json --config "$config" </dev/null \
    | jq -r '.[0].component.componentReferences | length')"
  [[ "$refs" -eq 2 ]] || die "platform does not have 2 references (got $refs)"
}

_tree() {
  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"
  "$OCM" get cv "$(_platform_ref)" --recursive --config "$config" -o tree </dev/null
}

_edges() {
  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"
  "$OCM" get cv "$(_platform_ref)" --recursive --config "$config" -o json </dev/null \
    | jq -r '
        .[] |
        .component.name as $parent |
        (.component.componentReferences // [])[] |
        [$parent, .componentName, (.digest.value // "none")[0:12]] |
        @tsv
      ' \
    | sort -u
}

_transfer() {
  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"

  "$OCM" transfer cv "$(_platform_ref)" "ctf::$GRAPH_FLAT_CTF" \
    --config "$config" </dev/null >/dev/null
  local flat_count
  flat_count="$(jq '[.artifacts[].repository] | unique | length' "$GRAPH_FLAT_CTF/artifact-index.json")"

  "$OCM" transfer cv "$(_platform_ref)" "ctf::$GRAPH_RELEASE_CTF" \
    --recursive --config "$config" </dev/null >/dev/null
  local release_count
  release_count="$(jq '[.artifacts[].repository] | unique | length' "$GRAPH_RELEASE_CTF/artifact-index.json")"

  printf 'flat\t%s repositories\n' "$flat_count"
  printf 'recursive\t%s repositories\n' "$release_count"

  if ! "$OCM" get cv "ctf::$GRAPH_RELEASE_CTF//${GRAPH_PLATFORM}:${VERSION}" \
    --recursive </dev/null >/dev/null; then
    die "release-ctf is NOT self-contained (recursive get failed)"
  fi
  echo "release-ctf is self-contained"
}

_plan() {
  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"
  "$OCM" transfer cv "$(_platform_ref)" "ctf::$GRAPH_DEMO_OUT/plan-ctf" \
    --recursive --dry-run -o json --config "$config" </dev/null \
    > "$GRAPH_DEMO_OUT/plan.json"
  jq -r '.transformations[] | select(.type == "CTFAddComponentVersion/v1alpha1") | .label' \
    "$GRAPH_DEMO_OUT/plan.json"
}

_tamper() {
  local config="$GRAPH_DEMO_OUT/resolvers.ocmconfig"
  local tampered_base="$GRAPH_DEMO_OUT/tampered-base-ctf"

  cp -R "$GRAPH_BASE_CTF" "$tampered_base"

  local tampered_config="$GRAPH_DEMO_OUT/tampered-resolvers.ocmconfig"
  _resolvers "$tampered_config" "$tampered_base" "$GRAPH_APPS_CTF"

  GRAPH_RUNTIME_TEXT="runtime-changed" \
    "$OCM" add cv --repository "ctf::$tampered_base" \
      --constructor "$ROOT/components/graph/runtime.yaml" \
      --component-version-conflict-policy replace </dev/null >/dev/null

  local err
  err="$("$OCM" transfer cv "$(_platform_ref)" "ctf::$GRAPH_DEMO_OUT/tampered-release-ctf" \
    --recursive --config "$tampered_config" </dev/null 2>&1 >/dev/null || true)"

  if echo "$err" | grep -q "digest mismatch"; then
    printf 'tamper\trejected\t%s\n' "$(echo "$err" | grep "digest mismatch" | head -1)"
  else
    die "expected digest mismatch but transfer succeeded or failed differently: $err"
  fi
}

mkdir -p "$GRAPH_DEMO_OUT"

case "${1:-}" in
  build)    _build ;;
  tree)     _tree ;;
  edges)    _edges ;;
  transfer) _transfer ;;
  plan)     _plan ;;
  tamper)   _tamper ;;
  *)        _build; echo ""; _tree; echo ""; _edges; echo ""; _transfer; echo ""; _plan; echo ""; _tamper ;;
esac
