#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq tar

HELM_DEMO_COMPONENT="github.com/lioramilbaum/helm-demo"
HELM_DEMO_CTF="${HELM_DEMO_CTF:-$BUILD_DIR/helm-ctf}"
HELM_DEMO_OUT="${HELM_DEMO_OUT:-$BUILD_DIR/helm}"
HELM_DEMO_CONSTRUCTOR="$ROOT/components/helm/component-constructor.yaml"
CHART_DIR="$ROOT/components/helm/chart/hello-world"
CHART_RESOURCE="hello-world-chart"
CHART_LAYER_MEDIA_TYPE="application/vnd.cncf.helm.chart.content.v1.tar+gzip"
CHART_CONFIG_MEDIA_TYPE="application/vnd.cncf.helm.config.v1+json"

CHART_VERSION="$(awk '/^version:/{gsub(/"/,"",$2);print $2}' "$CHART_DIR/Chart.yaml")"
[[ -n "$CHART_VERSION" ]] || die "cannot read chart version from $CHART_DIR/Chart.yaml"
export ROOT CHART_VERSION

helm_ref() {
  echo "ctf::${HELM_DEMO_CTF}//${HELM_DEMO_COMPONENT}:${VERSION}"
}

_build() {
  rm -rf "$HELM_DEMO_CTF"
  # shellcheck disable=SC2086
  "$OCM" add cv \
    --repository "ctf::$HELM_DEMO_CTF" \
    --constructor "$HELM_DEMO_CONSTRUCTOR" \
    ${OCM_ADD_FLAGS:-}
  local media_type
  media_type="$("$OCM" get cv "$(helm_ref)" -o json \
    | jq -r --arg r "$CHART_RESOURCE" \
      '.[0].component.resources[] | select(.name==$r) | .access.mediaType')"
  [[ "$media_type" == "application/vnd.oci.image.manifest.v1+json" ]] || \
    die "hello-world-chart is not an OCI artifact (got: $media_type)"
}

_sign() {
  "$OCM" sign cv \
    --config "$BUILD_DIR/sign.ocmconfig" \
    --signature default \
    "$(helm_ref)" < /dev/null
}

_verify() {
  "$OCM" verify cv \
    --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" \
    --signature default \
    "$(helm_ref)" < /dev/null
}

_download() {
  [[ "${SKIP_VERIFY:-}" == "1" ]] || _verify

  rm -rf "$HELM_DEMO_OUT/oci-layout" "$HELM_DEMO_OUT/chart"
  mkdir -p "$HELM_DEMO_OUT"

  "$OCM" download resource "$(helm_ref)" \
    --identity "name=$CHART_RESOURCE" \
    --output "$HELM_DEMO_OUT/oci-layout" >/dev/null

  "$OCM" download resource "$(helm_ref)" \
    --identity "name=$CHART_RESOURCE" \
    --transformer helm \
    --output "$HELM_DEMO_OUT/chart" >/dev/null

  local index="$HELM_DEMO_OUT/oci-layout/index.json"
  [[ -f "$index" ]] || die "OCI layout download failed: index.json not found"

  # (a) manifest digest in index must match descriptor digest.
  local manifest_digest
  manifest_digest="$(jq -r '.manifests[0].digest' "$index")"
  local descriptor_digest
  descriptor_digest="$("$OCM" get cv "$(helm_ref)" -o json \
    | jq -r --arg r "$CHART_RESOURCE" \
      '.[0].component.resources[] | select(.name==$r) | .access.localReference')"
  [[ "$manifest_digest" == "$descriptor_digest" ]] || \
    die "chart manifest digest mismatch (index=$manifest_digest, descriptor=$descriptor_digest)"

  # (b) sha256 of manifest blob must equal its name.
  local manifest_blob="$HELM_DEMO_OUT/oci-layout/blobs/sha256/${manifest_digest##sha256:}"
  [[ -f "$manifest_blob" ]] || die "manifest blob not found: $manifest_blob"
  local actual_manifest_digest
  actual_manifest_digest="sha256:$(sha256 "$manifest_blob")"
  [[ "$actual_manifest_digest" == "$manifest_digest" ]] || die "manifest blob digest mismatch"

  # (c) config mediaType must be the Helm config type.
  local config_media_type
  config_media_type="$(jq -r '.config.mediaType' "$manifest_blob")"
  [[ "$config_media_type" == "$CHART_CONFIG_MEDIA_TYPE" ]] || \
    die "not a Helm chart artifact (config.mediaType=$config_media_type)"

  # (d) layer digest must match sha256 of the extracted tgz.
  local tgz="$HELM_DEMO_OUT/chart/hello-world-${CHART_VERSION}.tgz"
  [[ -f "$tgz" ]] || die "chart tgz not found: $tgz"
  local layer_digest
  layer_digest="$(jq -r --arg mt "$CHART_LAYER_MEDIA_TYPE" \
    '.layers[] | select(.mediaType==$mt) | .digest' "$manifest_blob")"
  local actual_layer_digest
  actual_layer_digest="sha256:$(sha256 "$tgz")"
  [[ "$actual_layer_digest" == "$layer_digest" ]] || \
    die "chart digest mismatch (tgz=$actual_layer_digest, manifest=$layer_digest)"

  echo "$tgz"
}

_values() {
  [[ -d "$CTF" ]] || die "Application CTF not found: $CTF (run make build first)"
  [[ "${SKIP_VERIFY:-}" == "1" ]] || bash "$ROOT/scripts/verify.sh" >/dev/null

  local cv_json
  cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"
  local image_ref
  image_ref="$(echo "$cv_json" | jq -r \
    --arg arch "$TARGET_ARCH" \
    '.[0].component.resources[]
     | select(.name=="hello-world-image" and .extraIdentity.architecture==$arch)
     | .access.imageReference')"
  [[ -n "$image_ref" && "$image_ref" != "null" ]] || \
    die "hello-world-image for $TARGET_ARCH not found in $(cv_ref "$ROOT_COMPONENT")"

  local digest_value
  digest_value="$(echo "$cv_json" | jq -r \
    --arg arch "$TARGET_ARCH" \
    '.[0].component.resources[]
     | select(.name=="hello-world-image" and .extraIdentity.architecture==$arch)
     | .digest.value')"
  [[ -n "$digest_value" && "$digest_value" != "null" ]] || \
    die "digest not set for hello-world-image/$TARGET_ARCH — run make sign first"

  local image_no_digest="${image_ref%%@sha256:*}"
  local repository="${image_no_digest%:*}"
  local tag="${image_no_digest##*:}"

  local embedded_digest="${image_ref##*@}"
  [[ "$embedded_digest" == "sha256:$digest_value" ]] || \
    die "image digest mismatch (embedded=$embedded_digest, descriptor=sha256:$digest_value)"

  mkdir -p "$HELM_DEMO_OUT"
  local values_file="$HELM_DEMO_OUT/values.ocm.yaml"
  cat > "$values_file" <<EOF
# Generated by bash scripts/helm.sh values
# Source: $(cv_ref "$ROOT_COMPONENT") architecture=$TARGET_ARCH
image:
  repository: $repository
  tag: $tag
  digest: sha256:$digest_value
EOF
  echo "$values_file"
}

_show() {
  [[ -d "$HELM_DEMO_OUT/oci-layout" ]] || die "run scripts/helm.sh download first"

  local cv_json resource_json
  cv_json="$("$OCM" get cv "$(helm_ref)" -o json)"
  resource_json="$(echo "$cv_json" | jq -r \
    --arg r "$CHART_RESOURCE" \
    '.[0].component.resources[] | select(.name==$r)')"

  local res_version access_type access_media
  res_version="$(echo "$resource_json" | jq -r '.version')"
  access_type="$(echo "$resource_json"  | jq -r '.access.type')"
  access_media="$(echo "$resource_json" | jq -r '.access.mediaType')"

  local manifest_digest
  manifest_digest="$(jq -r '.manifests[0].digest' "$HELM_DEMO_OUT/oci-layout/index.json")"
  local manifest_blob="$HELM_DEMO_OUT/oci-layout/blobs/sha256/${manifest_digest##sha256:}"
  local config_media layer_media layer_digest ref_name
  config_media="$(jq -r '.config.mediaType' "$manifest_blob")"
  layer_media="$(jq -r --arg mt "$CHART_LAYER_MEDIA_TYPE" \
    '.layers[] | select(.mediaType==$mt) | .mediaType' "$manifest_blob")"
  layer_digest="$(jq -r --arg mt "$CHART_LAYER_MEDIA_TYPE" \
    '.layers[] | select(.mediaType==$mt) | .digest' "$manifest_blob")"
  ref_name="$(jq -r \
    '.manifests[0].annotations["org.opencontainers.image.ref.name"]' \
    "$HELM_DEMO_OUT/oci-layout/index.json")"

  printf '%s\t%s\t%s\t%s\n' "resource" "$CHART_RESOURCE" "helmChart" "$res_version"
  printf '%s\t%s\t%s\n'     "access"   "$access_type"    "$access_media"
  printf '%s\t%s\n'         "config"   "$config_media"
  printf '%s\t%s\t%s\n'     "layer"    "$layer_media"     "$layer_digest"
  printf '%s\t%s\n'         "tag"      "$ref_name"
  printf '%s\t%s\n'         "chart"    "hello-world-${CHART_VERSION}.tgz"
}

case "${1:-}" in
  build)    _build ;;
  sign)     _sign ;;
  verify)   _verify ;;
  download) _download ;;
  values)   _values ;;
  show)     _show ;;
  *)        _build; _sign; _verify; SKIP_VERIFY=1 _download; echo ""; _show ;;
esac
