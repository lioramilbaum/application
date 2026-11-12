#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/bootstrap-bundle.sh
source "$(dirname "$0")/bootstrap-bundle.sh"

# Connected side of the air-gapped path. `bundle` runs online and writes $BOOTSTRAP_BUNDLE_DIR: it is the only online
# step, so the bundle holds everything the target needs, the platform images included. `check` runs without network
# access and tells whether that bundle is complete and built from the current build/ctf, key and platform pins.
# docs/bootstrap.md.

HELM="${HELM:-helm}"
FLUX="${FLUX:-flux}"
export HELM FLUX
# Chart and Flux versions, and the chart registry references, live in scripts/controller.sh: the one place
# Renovate updates them and the one place the online defaults are written
_controller_version() {
  sed -n "s/^$1=\"\([^\"]*\)\"/\1/p" "$ROOT/scripts/controller.sh"
}
OCM_CONTROLLER_CHART_VERSION="$(_controller_version OCM_CONTROLLER_CHART_VERSION)"
KRO_CHART_VERSION="$(_controller_version KRO_CHART_VERSION)"
FLUX_VERSION="$(_controller_version FLUX_VERSION)"
OCM_CONTROLLER_CHART_REF="$(_controller_version OCM_CONTROLLER_CHART_REF)"
KRO_CHART_REF="$(_controller_version KRO_CHART_REF)"

# Written by bundle: the digests of the CTF index, the public key and the platform pins the bundle was built from
# (see _bundle_is_stale)
BOOTSTRAP_STAMP_FILE="source.stamp"
# Component that carries the platform images while they are saved; it lives only in a scratch CTF
PLATFORM_COMPONENT="github.com/lioramilbaum/application-platform"

# _platform_pins: the versions that decide which platform images a bundle holds. Tags are not resolved here,
# so check stays offline; a tag moved upstream is picked up by the next bundle.
_platform_pins() {
  printf '%s\n' "$OCM_CONTROLLER_CHART_VERSION" "$KRO_CHART_VERSION" "$FLUX_VERSION" "$BOOTSTRAP_REGISTRY_IMAGE"
}

# _bundle_stamp: digests of the CTF index, the public key and the platform pins that a bundle is built from
_bundle_stamp() {
  local pub="${VERIFY_KEY:-$BUILD_DIR/keys/public.pem}" index_digest key_digest pins_digest
  index_digest="$(sha256 "$CTF/artifact-index.json")" && key_digest="$(sha256 "$pub")" || return 1
  pins_digest="$(_platform_pins | sha256 /dev/stdin)" || return 1
  printf '%s %s %s\n' "$index_digest" "$key_digest" "$pins_digest"
}

# _bundle_is_stale: true when the bundle was built from a CTF, key or platform pins other than the current ones.
# Without a CTF there is nothing to compare with, so the bundle is kept.
_bundle_is_stale() {
  local current
  [[ -f "$CTF/artifact-index.json" ]] || return 1
  current="$(_bundle_stamp)" || return 0
  [[ "$(cat "$BOOTSTRAP_BUNDLE_DIR/$BOOTSTRAP_STAMP_FILE" 2>/dev/null || true)" != "$current" ]]
}

# _check_bundle_dir: BOOTSTRAP_BUNDLE_DIR is deleted and rebuilt, so it must be a subdirectory of BUILD_DIR
# with no empty, "." or ".." part, and no part below BUILD_DIR may be a symlink, which could point the
# deletion outside BUILD_DIR
_check_bundle_dir() {
  local rel="${BOOTSTRAP_BUNDLE_DIR#"$BUILD_DIR"/}" part path="$BUILD_DIR"
  local -a parts
  [[ "$BOOTSTRAP_BUNDLE_DIR" == "$BUILD_DIR"/* && -n "$rel" ]] || \
    die "BOOTSTRAP_BUNDLE_DIR must be a directory under BUILD_DIR ($BUILD_DIR), not $BOOTSTRAP_BUNDLE_DIR"
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.|..) die "BOOTSTRAP_BUNDLE_DIR must not contain empty, . or .. parts: $BOOTSTRAP_BUNDLE_DIR" ;;
    esac
    path="$path/$part"
    [[ ! -L "$path" ]] || die "BOOTSTRAP_BUNDLE_DIR must not pass through a symlink under BUILD_DIR: $path"
  done
}

# _pull_chart REF VERSION OUT: saves a Helm chart as the .tgz file OUT
_pull_chart() {
  local stage
  stage="$(mktemp -d)"
  "$HELM" pull "$1" --version "$2" --destination "$stage" >/dev/null
  ls "$stage"/*.tgz >/dev/null 2>&1 || die "helm pull $1 wrote no chart archive"
  mv "$stage"/*.tgz "$3"
  rm -rf "$stage"
}

# _image_refs: prints the container images named in the YAML on stdin, once each and without quotes
_image_refs() {
  sed -n -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//p' \
    | tr -d "\"'" | sed -E 's/[[:space:]]+$//' | awk 'NF' | sort -u
}

# _blob LAYOUT DIGEST: the path of DIGEST in the OCI layout LAYOUT
_blob() { echo "$1/blobs/${2%%:*}/${2#*:}"; }

# _platform_manifests LAYOUT ROOT: prints "<digest> <arch>" for each kept platform manifest under ROOT (an index
# or a single manifest)
_platform_manifests() {
  local root_blob arches
  root_blob="$(_blob "$1" "$2")"
  arches="$(printf '%s\n' "${BOOTSTRAP_IMAGE_ARCHES[@]}" | jq -R . | jq -sc .)"
  if jq -e '.manifests' "$root_blob" >/dev/null 2>&1; then
    jq -r --argjson a "$arches" \
      '.manifests[] | select(.platform.os == "linux" and (.platform.architecture as $x | $a | index($x))) | "\(.digest) \(.platform.architecture)"' \
      "$root_blob"
  else
    echo "$2 $(jq -r '.config.digest' "$root_blob" | xargs -I{} jq -r .architecture "$(_blob "$1" {})")"
  fi
}

# _prune_layout LAYOUT ROOT: keeps the ROOT blob byte for byte (its digest is the pinned one) and only the
# linux manifests of BOOTSTRAP_IMAGE_ARCHES with their configs and layers. Other platforms, attestations and
# signatures are removed: nothing on the target runs or reads them.
_prune_layout() {
  local layout="$1" root="$2" m _ f d
  local -a keep=("$root")
  while read -r m _; do
    keep+=("$m")
    mapfile -t -O "${#keep[@]}" keep < <(jq -r '.config.digest, .layers[].digest' "$(_blob "$layout" "$m")")
  done < <(_platform_manifests "$layout" "$root")
  (( ${#keep[@]} > 1 )) || die "platform image $root has no linux manifest for ${BOOTSTRAP_IMAGE_ARCHES[*]}"
  for f in "$layout"/blobs/*/*; do
    d="$(basename "$(dirname "$f")"):$(basename "$f")"
    printf '%s\n' "${keep[@]}" | grep -qxF "$d" || rm -f "$f"
  done
  for d in "${keep[@]}"; do
    [[ -f "$(_blob "$layout" "$d")" ]] || die "platform image $root: blob $d is missing from the download"
  done
}

# _tar_layout LAYOUT OUT: archives an OCI layout with plain member names (index.json, blobs/...)
_tar_layout() {
  local -a members=(oci-layout index.json blobs)
  [[ -f "$1/manifest.json" ]] && members+=(manifest.json)
  tar -C "$1" -cf "$2" "${members[@]}"
}

# _write_node_archive LAYOUT ROOT REF OUT: names ROOT in the layout's index.json by every name the nodes look REF up
# by (io.containerd.image.name, read by ctr images import) and archives it
_write_node_archive() {
  local layout="$1" root="$2" ref="$3" out="$4" media size
  media="$(jq -r '.mediaType // "application/vnd.oci.image.index.v1+json"' "$(_blob "$layout" "$root")")"
  size="$(wc -c < "$(_blob "$layout" "$root")" | tr -d ' ')"
  _image_names "$ref" "$root" | jq -R . | jq -s --arg d "$root" --arg m "$media" --argjson s "$size" \
    '{schemaVersion: 2, manifests: [.[] | {mediaType: $m, digest: $d, size: $s,
      annotations: {"io.containerd.image.name": ., "org.opencontainers.image.ref.name": .}}]}' > "$layout/index.json"
  _tar_layout "$layout" "$out"
}

# _write_registry_archive LAYOUT ROOT OUT: the registry runs on the host, where the Docker image load names images. Each
# kept platform manifest gets its own tag, $BOOTSTRAP_REGISTRY_LOCAL_REF-<arch>, in index.json (containerd image
# store) and in a Docker manifest.json (classic image store). The containerd store keeps io.containerd.image.name as
# written but Docker looks names up normalized, so index.json carries the name with its registry; ref.name is the tag
# alone, as the OCI layout spec defines it. manifest.json keeps the short name. Either way the image is found as
# $BOOTSTRAP_REGISTRY_LOCAL_REF-<arch>. The pinned index blob stays in the archive, so the target can check the
# manifest it runs against the pin.
_write_registry_archive() {
  local layout="$1" root="$2" out="$3" entries="[]" legacy="[]" m arch mf size
  while read -r m arch; do
    mf="$(_blob "$layout" "$m")"
    size="$(wc -c < "$mf" | tr -d ' ')"
    entries="$(jq -c --arg d "$m" --argjson s "$size" --arg n "$(_image_repo "$BOOTSTRAP_REGISTRY_LOCAL_REF"):${BOOTSTRAP_REGISTRY_LOCAL_REF##*:}-$arch" \
      --arg t "${BOOTSTRAP_REGISTRY_LOCAL_REF##*:}-$arch" --arg mt "$(jq -r '.mediaType // "application/vnd.oci.image.manifest.v1+json"' "$mf")" \
      '. + [{mediaType: $mt, digest: $d, size: $s, annotations: {"io.containerd.image.name": $n, "org.opencontainers.image.ref.name": $t}}]' <<< "$entries")"
    legacy="$(jq -c --arg n "$BOOTSTRAP_REGISTRY_LOCAL_REF-$arch" \
      --arg c "blobs/$(jq -r '.config.digest | sub(":"; "/")' "$mf")" \
      --argjson l "$(jq -c '[.layers[].digest | "blobs/" + sub(":"; "/")]' "$mf")" \
      '. + [{Config: $c, RepoTags: [$n], Layers: $l}]' <<< "$legacy")"
  done < <(_platform_manifests "$layout" "$root")
  jq -n --argjson m "$entries" '{schemaVersion: 2, manifests: $m}' > "$layout/index.json"
  printf '%s\n' "$legacy" > "$layout/manifest.json"
  _tar_layout "$layout" "$out"
}

# _save_platform_images: online. Saves every platform image the bundle names: images.txt (the nodes) and the
# registry image (the host). OCM resolves each reference to the digest of its upstream index and downloads it as
# an OCI layout by that digest; a pinned reference must resolve to its pin.
_save_platform_images() {
  local work="$BUILD_DIR/platform-images" cv i ref name digest pinned layout
  local -a refs
  mapfile -t refs < "$BOOTSTRAP_BUNDLE_DIR/images.txt"
  refs+=("$BOOTSTRAP_REGISTRY_IMAGE")
  rm -rf "$work"
  mkdir -p "$work" "$BOOTSTRAP_BUNDLE_DIR/images"
  # Written as JSON, which is also YAML. OCM resolves full references only, so registry:2 is written with its registry
  for ref in "${refs[@]}"; do _image_full_ref "$ref"; done | jq -R . | jq -s --arg c "$PLATFORM_COMPONENT" --arg v "$VERSION" --argjson last "$(( ${#refs[@]} - 1 ))" '{
    components: [{name: $c, version: $v, provider: {name: "lioramilbaum"},
      resources: [to_entries[] | {
        name: (if .key == $last then "platform-registry" else "platform-image-\(.key)" end),
        version: $v, type: "ociImage",
        access: {type: "OCIImage/v1", imageReference: .value}}]}]}' > "$work/component-constructor.yaml"
  "$OCM" add cv --repository "ctf::$work/ctf" --constructor "$work/component-constructor.yaml" </dev/null >/dev/null
  cv="$("$OCM" get cv "ctf::$work/ctf//$PLATFORM_COMPONENT:$VERSION" -o json </dev/null)"
  for i in "${!refs[@]}"; do
    ref="${refs[$i]}"
    if (( i == ${#refs[@]} - 1 )); then name=platform-registry; else name="platform-image-$i"; fi
    digest="sha256:$(jq -r --arg n "$name" '.[0].component.resources[] | select(.name == $n) | .digest.value' <<< "$cv")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "platform image $ref has no digest in the descriptor"
    if [[ "$ref" == *@sha256:* ]]; then
      pinned="sha256:${ref##*@sha256:}"
      [[ "$digest" == "$pinned" ]] || die "platform image $ref resolved to $digest, not its pinned digest"
    fi
    layout="$work/layout-$i"
    "$OCM" download resource "ctf::$work/ctf//$PLATFORM_COMPONENT:$VERSION" --identity "name=$name" \
      --output "$layout" </dev/null >/dev/null
    jq -e --arg d "$digest" 'any(.manifests[]; .digest == $d)' "$layout/index.json" >/dev/null \
      || die "downloaded layout for $ref does not hold $digest"
    _prune_layout "$layout" "$digest"
    if [[ "$name" == platform-registry ]]; then
      _write_registry_archive "$layout" "$digest" "$BOOTSTRAP_BUNDLE_DIR/images/registry.tar"
    else
      _write_node_archive "$layout" "$digest" "$ref" "$BOOTSTRAP_BUNDLE_DIR/$(_image_archive "$ref")"
    fi
  done
  rm -rf "$work"
}

# bundle: online. Writes $BOOTSTRAP_BUNDLE_DIR with everything the offline target needs.
_bundle() {
  # Checked before anything is removed: the rm below must never reach outside BUILD_DIR
  _check_bundle_dir
  require "$OCM" "$HELM" "$FLUX" jq tar
  local pub="${VERIFY_KEY:-$BUILD_DIR/keys/public.pem}" chart
  [[ -d "$CTF" ]] || die "no component archive at $CTF (run: make build sign)"
  [[ -f "$pub" ]] || die "public key not found: $pub (run: make sign)"
  [[ -n "$OCM_CONTROLLER_CHART_VERSION" && -n "$KRO_CHART_VERSION" && -n "$FLUX_VERSION" ]] || \
    die "could not read chart and Flux versions from scripts/controller.sh"

  rm -rf "${BOOTSTRAP_BUNDLE_DIR:?}"
  mkdir -p "$BOOTSTRAP_BUNDLE_DIR/charts" "$BOOTSTRAP_BUNDLE_DIR/flux"

  # Inline every external resource (the nginx image) so the bundle needs no registry access on the target
  env -u OCM_COMPONENT_REPO OCM_REPO="ctf::$BOOTSTRAP_BUNDLE_DIR/ctf" bash "$ROOT/scripts/publish.sh"
  _verify_config "$pub" "$BOOTSTRAP_VERIFY_CONFIG"
  "$OCM" verify cv --config "$BOOTSTRAP_VERIFY_CONFIG" --signature default \
    "$(bundle_ref)" </dev/null >/dev/null

  _pull_chart "$OCM_CONTROLLER_CHART_REF" "$OCM_CONTROLLER_CHART_VERSION" "$BOOTSTRAP_BUNDLE_DIR/charts/ocm-k8s-toolkit.tgz"
  _pull_chart "$KRO_CHART_REF" "${KRO_CHART_VERSION#v}" "$BOOTSTRAP_BUNDLE_DIR/charts/kro.tgz"
  "$FLUX" install --export --version "$FLUX_VERSION" \
    --components source-controller,kustomize-controller > "$BOOTSTRAP_BUNDLE_DIR/flux/install.yaml"

  # Node images: every container image the charts and Flux deploy. The registry image runs on the host, not on
  # the nodes, so it is saved separately (images/registry.tar)
  {
    for chart in "$BOOTSTRAP_BUNDLE_DIR"/charts/*.tgz; do
      "$HELM" template bundle "$chart"
    done
    cat "$BOOTSTRAP_BUNDLE_DIR/flux/install.yaml"
  } | _image_refs > "$BOOTSTRAP_BUNDLE_DIR/images.txt"
  _save_platform_images

  cp "$pub" "$BOOTSTRAP_BUNDLE_DIR/public.pem"
  _bundle_stamp > "$BOOTSTRAP_BUNDLE_DIR/$BOOTSTRAP_STAMP_FILE"
  echo "bootstrap bundle written to $BOOTSTRAP_BUNDLE_DIR ($(wc -l < "$BOOTSTRAP_BUNDLE_DIR/images.txt" | tr -d ' ') node images and the registry image, ${BOOTSTRAP_IMAGE_ARCHES[*]})"
}

# check: no network. Exits 1 when the bundle is incomplete or was built from another build/ctf, key or platform pins
_check() {
  local missing
  missing="$(_missing_bundle_file)"
  if [[ -n "$missing" ]]; then
    echo "missing $missing"
    return 1
  fi
  if _bundle_is_stale; then
    echo "stale"
    return 1
  fi
  echo "bundle at $BOOTSTRAP_BUNDLE_DIR is current"
}

cmd="${1:-}"
case "$cmd" in
  bundle) _bundle ;;
  check)  _check ;;
  *) die "usage: sourcectl.sh bundle|check" ;;
esac
