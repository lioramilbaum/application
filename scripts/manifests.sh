#!/usr/bin/env bash
set -euo pipefail
# OCM v0.19.0 hangs on open stdin pipes; close stdin for the whole script.
exec < /dev/null
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

[[ "$(echo "$cv_json" | jq 'length')" -eq 1 ]] || \
  die "Expected exactly 1 component version, got: $(echo "$cv_json" | jq 'length')"

img="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .access.imageReference')"

[[ "$img" =~ @sha256:[0-9a-f]{64}$ ]] || \
  die "hello-world-image is not pinned by digest (got: $img)"

expected_digest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-image") | .digest.value')"
actual_digest="${img##*@sha256:}"
[[ "$actual_digest" == "$expected_digest" ]] || \
  die "image digest mismatch (imageReference: $actual_digest, descriptor: $expected_digest)"

mkdir -p "$DEPLOY_DIR"

src="$DEPLOY_DIR/hello-world.src.yaml"
out="$DEPLOY_DIR/hello-world.yaml"

# ocm v0.17 appends to an existing output file instead of truncating it.
rm -f "$src"
"$OCM" download resource \
  "$(cv_ref "$ROOT_COMPONENT")" \
  --identity name=hello-world-manifests \
  --output "$src"

blob_digest="$(echo "$cv_json" | jq -r '.[0].component.resources[] | select(.name=="hello-world-manifests") | .digest.value')"
actual_blob="$(sha256 "$src")"
[[ "$actual_blob" == "$blob_digest" ]] || \
  die "manifests blob digest mismatch (expected $blob_digest, got $actual_blob)"

sed "s|$IMAGE_PLACEHOLDER|$img|g" "$src" > "$out"

grep -q "$IMAGE_PLACEHOLDER" "$out" && die "IMAGE_PLACEHOLDER still present in rendered manifest"

echo "Manifests rendered to $out (image: $img)"
