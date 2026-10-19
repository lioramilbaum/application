#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq python3 tar

OCI_COMPONENT="github.com/lioramilbaum/oci-demo"
OCI_DEMO_CTF="${OCI_DEMO_CTF:-$BUILD_DIR/oci-ctf}"
OCI_DEMO_OUT="${OCI_DEMO_OUT:-$BUILD_DIR/oci}"
OCI_DEMO_CONSTRUCTOR="$ROOT/components/oci/component-constructor.yaml"
OCI_RELOCATE_CONFIG="$ROOT/components/oci/relocate.ocmconfig"
OCI_TARGET="${OCI_TARGET:-oci::http://registry.example.invalid/mirror}"

# <resource name> <architecture label>; "multiarch" marks the image index.
OCI_VARIANTS=("hello-image amd64" "hello-image arm64" "hello-image-multiarch multiarch")

_oci_ref() {
  echo "ctf::${OCI_DEMO_CTF}//${OCI_COMPONENT}:${VERSION}"
}

_cv_resources() {
  "$OCM" get cv "$(_oci_ref)" -o json < /dev/null | jq -c '.[0].component.resources[]'
}

_build() {
  rm -rf "$OCI_DEMO_CTF"
  "$OCM" add cv \
    --repository "ctf::$OCI_DEMO_CTF" \
    --constructor "$OCI_DEMO_CONSTRUCTOR" \
    --config "$BUILD_DIR/verify.ocmconfig" < /dev/null >/dev/null
}

_sign() {
  "$OCM" sign cv \
    --config "$BUILD_DIR/sign.ocmconfig" \
    --signature default \
    "$(_oci_ref)" < /dev/null
}

_verify() {
  "$OCM" verify cv \
    --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" \
    --signature default \
    "$(_oci_ref)" < /dev/null
}

# _blob <layout-dir> <sha256:digest>: prints the blob path after checking its content hash
_blob() {
  local dir="$1" digest="$2" path
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$dir: malformed digest '$digest'"
  path="$dir/blobs/${digest/://}"
  [[ -f "$path" ]] || die "$dir: missing blob $digest"
  [[ "$(sha256 "$path")" == "${digest#sha256:}" ]] || die "$dir: blob $digest does not match its digest"
  echo "$path"
}

# _images <layout-dir> <descriptor-hex> <arch>: prints "<manifest-digest> <arch>" per single-arch image
_images() {
  local dir="$1" hex="$2" arch="$3" index
  if [[ "$arch" != multiarch ]]; then
    echo "sha256:$hex $arch"
    return
  fi
  index="$(_blob "$dir" "sha256:$hex")"
  jq -r '.manifests[] | "\(.digest) \(.platform.architecture)"' "$index"
}

# _check_image <layout-dir> <manifest-digest> <arch>
_check_image() {
  local dir="$1" digest="$2" arch="$3" manifest config layer got
  manifest="$(_blob "$dir" "$digest")"
  config="$(_blob "$dir" "$(jq -r '.config.digest' "$manifest")")"
  got="$(jq -r '.architecture' "$config")"
  [[ "$got" == "$arch" ]] || die "$dir: config architecture '$got', expected '$arch'"
  layer="$(_blob "$dir" "$(jq -r '.layers[0].digest' "$manifest")")"
  got="$(tar -xOf "$layer" hello.txt)"
  [[ "$got" == "hello from $arch" ]] || die "$dir: hello.txt is '$got', expected 'hello from $arch'"
}

# _check_layout <layout-dir> <descriptor-hex> <arch>
_check_layout() {
  local dir="$1" hex="$2" arch="$3" images digest variant
  jq -e --arg d "sha256:$hex" '.manifests[] | select(.digest == $d)' "$dir/index.json" >/dev/null \
    || die "$dir: index.json does not reference sha256:$hex"
  images="$(_images "$dir" "$hex" "$arch")"
  while read -r digest variant; do
    _check_image "$dir" "$digest" "$variant"
  done <<<"$images"
}

_download() {
  _verify >/dev/null
  mkdir -p "$OCI_DEMO_OUT"
  local name arch dir identity desc cv
  OCI_STAGE="$(mktemp -d "$OCI_DEMO_OUT/.download.XXXXXX")"
  trap 'rm -rf "$OCI_STAGE"' EXIT
  cv="$("$OCM" get cv "$(_oci_ref)" -o json < /dev/null)"

  for variant in "${OCI_VARIANTS[@]}"; do
    read -r name arch <<<"$variant"
    if [[ "$arch" == multiarch ]]; then
      dir="$name"
      identity="name=$name"
    else
      dir="$name-$arch"
      identity="name=$name,architecture=$arch"
    fi
    "$OCM" download resource \
      --identity "$identity" \
      --output "$OCI_STAGE/$dir" \
      "$(_oci_ref)" < /dev/null >/dev/null
    desc="$(jq -r --arg n "$name" --arg a "$arch" \
      '.[0].component.resources[] | select(.name == $n and ((.extraIdentity.architecture // "multiarch") == $a)) | .digest.value' <<<"$cv")"
    _check_layout "$OCI_STAGE/$dir" "$desc" "$arch"
  done

  rm -rf "$OCI_DEMO_OUT/download"
  mv "$OCI_STAGE" "$OCI_DEMO_OUT/download"
  trap - EXIT
  for variant in "${OCI_VARIANTS[@]}"; do
    read -r name arch <<<"$variant"
    if [[ "$arch" == multiarch ]]; then echo "$OCI_DEMO_OUT/download/$name"; else echo "$OCI_DEMO_OUT/download/$name-$arch"; fi
  done
}

_show() {
  _cv_resources | jq -r '[ "resource", .name, (.extraIdentity.architecture // "multiarch"), .type, ("sha256:" + .digest.value)] | @tsv'
}

_inspect() {
  _download >/dev/null
  local name arch mtype digest dir images image_digest image_arch layer
  while IFS=$'\t' read -r name arch mtype digest; do
    printf 'image\t%s\t%s\t%s\t%s\n' "$name" "$arch" "$mtype" "$digest"
    if [[ "$arch" == multiarch ]]; then dir="$OCI_DEMO_OUT/download/$name"; else dir="$OCI_DEMO_OUT/download/$name-$arch"; fi
    images="$(_images "$dir" "${digest#sha256:}" "$arch")"
    while read -r image_digest image_arch; do
      layer="$(jq -r '.layers[0].digest' "$(_blob "$dir" "$image_digest")")"
      printf 'layer\t%s\t%s\t%s\t%s\n' "$name" "$image_arch" "$layer" \
        "$(tar -xOf "$(_blob "$dir" "$layer")" hello.txt)"
    done <<<"$images"
  done < <(_cv_resources | jq -r '[.name, (.extraIdentity.architecture // "multiarch"), .access.mediaType, ("sha256:" + .digest.value)] | @tsv')
}

# _plan <mode> [transfer flags...]: dry-run to OCI_TARGET and print the transformation counts per type
_plan() {
  local mode="$1"
  shift
  local out="$OCI_DEMO_OUT/plan-$mode.json"
  mkdir -p "$OCI_DEMO_OUT"
  "$OCM" transfer cv --dry-run -o json "$@" "$(_oci_ref)" "$OCI_TARGET" < /dev/null >"$out"
  printf '%s\t%s\n' "$mode" \
    "$(jq -r '[.transformations[].type] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$out")"
}

_plans() {
  _plan plain
  _plan copy-resources --copy-resources
  _plan uploader --config "$OCI_RELOCATE_CONFIG"
}

_relocate() {
  mkdir -p "$OCI_DEMO_OUT"
  local plan="$OCI_DEMO_OUT/relocate-plan.json" before name arch digest node
  "$OCM" transfer cv --dry-run -o json --config "$OCI_RELOCATE_CONFIG" \
    "$(_oci_ref)" "$OCI_TARGET" < /dev/null >"$plan"

  before="$(_cv_resources | jq -r \
    '[.name, (.extraIdentity.architecture // "multiarch"), .access.type, (.access.localReference // "-"), ("sha256:" + .digest.value)] | @tsv')"
  while IFS= read -r line; do
    printf 'before\t%s\n' "$line"
  done <<<"$before"

  while IFS=$'\t' read -r name arch _; do
    node="$(jq -c --arg n "$name" '[.transformations[] | select(.type == "AddOCIArtifact/v1alpha1" and (.label | contains("Add \($n) as OCIArtifact")))] | .[0]' "$plan")"
    jq -e --arg n "$name" '.label | contains("Add \($n) as OCIArtifact")' <<<"$node" >/dev/null \
      || die "relocate plan has no uploader transfer for $name"
    # The plan takes the digest from the source resource; it is not recomputed on upload.
    jq -e '.spec.resource.digest | contains("output.resource.digest")' <<<"$node" >/dev/null \
      || die "relocate plan does not pass through the source digest for $name"
    printf 'after\t%s\t%s\t%s\t%s\n' "$name" "$arch" \
      "$(jq -r '.spec.resource.access.type' <<<"$node")" \
      "$(jq -r '.spec.resource.access.imageReference' <<<"$node")"
  done <<<"$before"
}

mkdir -p "$OCI_DEMO_OUT"

case "${1:-}" in
  build)    _build ;;
  sign)     _sign ;;
  verify)   _verify ;;
  download) _download ;;
  inspect)  _inspect ;;
  plan)     _plans ;;
  relocate) _relocate ;;
  show)     _show ;;
  *)        _build; _sign; _verify; _download >/dev/null; _show ;;
esac
