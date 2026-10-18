#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq tar gzip

OWNERSHIP_COMPONENT="github.com/lioramilbaum/ownership-demo"
OWNERSHIP_CTF="${OWNERSHIP_CTF:-$BUILD_DIR/ownership-ctf}"
OWNERSHIP_INPUT_DIR="$BUILD_DIR/ownership"
export ROOT OWNERSHIP_INPUT_DIR

OWNERSHIP_CONSTRUCTOR="$ROOT/components/ownership/component-constructor.yaml"

# blob_put <layout> <staged_file>
# Moves <staged_file> to its content-addressed name in the layout; prints "<digest> <size>".
blob_put() {
  local layout="$1" file="$2" digest size
  digest="$(sha256 "$file")"
  size="$(wc -c < "$file" | tr -d ' ')"
  mv "$file" "$layout/blobs/sha256/$digest"
  printf '%s %s\n' "$digest" "$size"
}

# oci_layout <html_file> <out.tar.gz>
# Builds a minimal OCI image layout containing one text/html layer,
# then tars and gzips it into the output file.
oci_layout() {
  local html="$1" out="$2"
  local layout
  layout="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$layout'" RETURN

  # OCI layout marker
  printf '{"imageLayoutVersion":"1.0.0"}' > "$layout/oci-layout"

  mkdir -p "$layout/blobs/sha256"

  # Layer: the HTML file
  cp "$html" "$layout/blobs/sha256/.layer"
  local layer_digest layer_size
  read -r layer_digest layer_size < <(blob_put "$layout" "$layout/blobs/sha256/.layer")

  # Config: empty
  printf '{}' > "$layout/blobs/sha256/.config"
  local cfg_digest cfg_size
  read -r cfg_digest cfg_size < <(blob_put "$layout" "$layout/blobs/sha256/.config")

  # Manifest
  local manifest_bytes manifest_digest manifest_size
  manifest_bytes="$(jq -cn \
    --arg cfg_digest "sha256:$cfg_digest" \
    --argjson cfg_size "$cfg_size" \
    --arg layer_digest "sha256:$layer_digest" \
    --argjson layer_size "$layer_size" \
    '{
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      artifactType: "application/vnd.lioramilbaum.hello-world.site.v1",
      config: {mediaType: "application/vnd.oci.empty.v1+json", digest: $cfg_digest, size: $cfg_size},
      layers: [{mediaType: "text/html", digest: $layer_digest, size: $layer_size}]
    }')"
  printf '%s' "$manifest_bytes" > "$layout/blobs/sha256/.manifest"
  read -r manifest_digest manifest_size < <(blob_put "$layout" "$layout/blobs/sha256/.manifest")

  # index.json
  jq -cn \
    --arg manifest_digest "sha256:$manifest_digest" \
    --argjson manifest_size "$manifest_size" \
    '{
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests: [{
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        digest: $manifest_digest,
        size: $manifest_size,
        artifactType: "application/vnd.lioramilbaum.hello-world.site.v1"
      }]
    }' > "$layout/index.json"

  tar -C "$layout" -czf "$out" .
}

_prepare_inputs() {
  mkdir -p "$OWNERSHIP_INPUT_DIR"
  oci_layout "$ROOT/components/ownership/site/index.html" \
    "$OWNERSHIP_INPUT_DIR/hello-world-site.oci.tar.gz"
  oci_layout "$ROOT/components/ownership/site-untracked/index.html" \
    "$OWNERSHIP_INPUT_DIR/hello-world-site-untracked.oci.tar.gz"
}

_add_cv() {
  # Inputs live under $BUILD_DIR and $ROOT, which share no directory below /,
  # so the working directory must be / for OCM to accept both.
  # shellcheck disable=SC2086
  "$OCM" add cv \
    --repository "ctf::$OWNERSHIP_CTF" \
    --constructor "$OWNERSHIP_CONSTRUCTOR" \
    --working-directory / \
    ${OCM_ADD_FLAGS:-}
}

_build() {
  rm -rf "$OWNERSHIP_CTF"
  _prepare_inputs
  _add_cv
}

# readd: add the component version into an EXISTING CTF (no rm -rf).
# Use with OCM_ADD_FLAGS=--component-version-conflict-policy replace to test idempotency.
_readd() {
  _prepare_inputs
  _add_cv
}

_cv_json() {
  "$OCM" get cv "ctf::${OWNERSHIP_CTF}//${OWNERSHIP_COMPONENT}:${VERSION}" -o json
}

_referrers_tag() {
  # Convert "sha256:<hex>" → "sha256-<hex>" (OCI referrers tag schema)
  printf '%s' "$1" | sed 's/:/-/'
}

_trace() {
  local cv_json
  cv_json="$(_cv_json)"

  local repo="component-descriptors/$OWNERSHIP_COMPONENT"

  jq -r '.[0].component.resources[] | [.name, .access.localReference] | @tsv' \
    <<<"$cv_json" | while IFS=$'\t' read -r name local_ref; do

    # Only OCI manifests can have ownership records
    local media_type
    media_type="$(jq -r --arg n "$name" \
      '.[0].component.resources[] | select(.name==$n) | .access.mediaType // ""' \
      <<<"$cv_json")"

    if [[ "$media_type" != "application/vnd.oci.image.manifest.v1+json" ]]; then
      printf '%s\t-\tno ownership record (not an OCI manifest)\n' "$name"
      continue
    fi

    local tag artifact_index
    tag="$(_referrers_tag "$local_ref")"
    artifact_index="$OWNERSHIP_CTF/artifact-index.json"

    # Find the referrers tag entry
    local referrers_digest
    referrers_digest="$(jq -r \
      --arg repo "$repo" --arg tag "$tag" \
      '[.artifacts[] | select(.repository==$repo and .tag==$tag)] | first | .digest // ""' \
      "$artifact_index")"

    if [[ -z "$referrers_digest" || "$referrers_digest" == "null" ]]; then
      printf '%s\t-\tno ownership record\n' "$name"
      continue
    fi

    # Open the referrers index blob
    local ref_index_blob
    ref_index_blob="$OWNERSHIP_CTF/blobs/${referrers_digest/:/.}"
    [[ -f "$ref_index_blob" ]] || die "referrers index blob not found: $ref_index_blob"

    # Find the ownership-typed manifest in the referrers index
    local ownership_manifest_digest
    ownership_manifest_digest="$(jq -r \
      '[.manifests[] | select(.artifactType=="application/vnd.ocm.software.ownership.v1+json")] | first | .digest // ""' \
      "$ref_index_blob")"

    if [[ -z "$ownership_manifest_digest" || "$ownership_manifest_digest" == "null" ]]; then
      printf '%s\t-\tno ownership record\n' "$name"
      continue
    fi

    # Open the ownership manifest and validate subject digest
    local ownership_manifest_blob
    ownership_manifest_blob="$OWNERSHIP_CTF/blobs/${ownership_manifest_digest/:/.}"
    [[ -f "$ownership_manifest_blob" ]] || die "ownership manifest blob not found: $ownership_manifest_blob"

    local subject_digest ann_name ann_version ann_artifact
    subject_digest="$(jq -r '.subject.digest' "$ownership_manifest_blob")"
    ann_name="$(jq -r '.annotations["software.ocm.component.name"]' "$ownership_manifest_blob")"
    ann_version="$(jq -r '.annotations["software.ocm.component.version"]' "$ownership_manifest_blob")"
    ann_artifact="$(jq -r '.annotations["software.ocm.artifact"]' "$ownership_manifest_blob")"

    [[ "$subject_digest" == "$local_ref" ]] || \
      die "$name: subject digest mismatch (record=$subject_digest, descriptor=$local_ref)"

    printf '%s\t%s:%s\t%s\n' "$name" "$ann_name" "$ann_version" "$ann_artifact"
  done
}

case "${1:-}" in
  build)   _build ;;
  readd)   _readd ;;
  trace)   _trace ;;
  *)       _build; echo ""; _trace ;;
esac
