#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" jq "$KUBECTL"

if [[ "${SKIP_VERIFY:-0}" != "1" ]]; then
  # shellcheck source=scripts/verify.sh
  source "$(dirname "$0")/verify.sh"
fi

cv_json="$("$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" -o json)"

[[ "$(echo "$cv_json" | jq 'length')" -eq 1 ]] || \
  die "Expected exactly 1 component version, got: $(echo "$cv_json" | jq 'length')"

res() {
  local matches count
  matches="$(jq -c --arg n "$1" --arg a "$TARGET_ARCH" \
    '[.[0].component.resources[] | select(.name==$n and ((.extraIdentity.architecture // $a) == $a))]' \
    <<<"$cv_json")"
  count="$(jq length <<<"$matches")"
  [[ "$count" -eq 1 ]] || die "expected exactly one $1 resource for architecture $TARGET_ARCH, got $count"
  jq -c '.[0]' <<<"$matches"
}

res_digest() { res "$1" | jq -r '.digest.value'; }

mkdir -p "$DEPLOY_DIR"

# Download and verify manifests blob
src="$DEPLOY_DIR/hello-world.src.yaml"
rm -f "$src"
"$OCM" download resource \
  "$(cv_ref "$ROOT_COMPONENT")" \
  --identity name="$MANIFESTS_RESOURCE" \
  --output "$src"

manifests_digest="$(res_digest "$MANIFESTS_RESOURCE")"
actual_manifests="$(sha256 "$src")"
[[ "$actual_manifests" == "$manifests_digest" ]] || \
  die "manifests blob digest mismatch (expected $manifests_digest, got $actual_manifests)"

# Download and verify localization rules
loc="$DEPLOY_DIR/hello-world.localization.json"
rm -f "$loc"
"$OCM" download resource \
  "$(cv_ref "$ROOT_COMPONENT")" \
  --identity name="$LOCALIZATION_RESOURCE" \
  --output "$loc"

loc_digest="$(res_digest "$LOCALIZATION_RESOURCE")"
actual_loc="$(sha256 "$loc")"
[[ "$actual_loc" == "$loc_digest" ]] || \
  die "localization blob digest mismatch (expected $loc_digest, got $actual_loc)"

# Validate localization config
loc_api="$(jq -r '.apiVersion' "$loc")"
loc_kind="$(jq -r '.kind' "$loc")"
loc_count="$(jq '.localizations | length' "$loc")"
[[ "$loc_api" == "localization.application.lioramilbaum.github.com/v1alpha1" && \
   "$loc_kind" == "LocalizationConfig" && \
   "$loc_count" -ge 1 ]] || \
  die "unsupported localization config (apiVersion=$loc_api kind=$loc_kind count=$loc_count)"

# Build kustomize patches from localization rules
patches="[]"
expected_images=()

while IFS= read -r rule; do
  rname="$(echo "$rule" | jq -r '.resource.name')"
  res_entry="$(res "$rname")"
  [[ -n "$res_entry" ]] || die "localization references unknown resource: $rname"

  img="$(echo "$res_entry" | jq -r '.access.imageReference')"
  expected_digest="$(echo "$res_entry" | jq -r '.digest.value')"
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || \
    die "$rname has no valid sha256 digest in the descriptor"

  # Strip http:// or https:// scheme (present after ocm transfer --copy-resources)
  img="${img#http://}"
  img="${img#https://}"

  if [[ "$img" =~ @sha256:[0-9a-f]{64}$ ]]; then
    actual_digest="${img##*@sha256:}"
    [[ "$actual_digest" == "$expected_digest" ]] || \
      die "image digest mismatch (imageReference: $actual_digest, descriptor: $expected_digest)"
  else
    img="${img}@sha256:${expected_digest}"
  fi

  tgt_kind="$(echo "$rule" | jq -r '.target.kind')"
  tgt_name="$(echo "$rule" | jq -r '.target.name')"
  cidx="$(echo "$rule" | jq -r '.container.index')"
  cname="$(echo "$rule" | jq -r '.container.name')"

  patch="$(jq -cn \
    --arg kind "$tgt_kind" \
    --arg name "$tgt_name" \
    --arg path_test "/spec/template/spec/containers/${cidx}/name" \
    --arg val_test "$cname" \
    --arg path_img "/spec/template/spec/containers/${cidx}/image" \
    --arg img "$img" \
    '{
      target: {kind: $kind, name: $name},
      patch: ([
        {op:"test",  path: $path_test, value: $val_test},
        {op:"replace",path: $path_img,  value: $img}
      ] | tojson)
    }')"

  patches="$(echo "$patches" | jq --argjson p "$patch" '. + [$p]')"
  expected_images+=("$img")
done < <(jq -c '.localizations[]' "$loc")

# Write kustomization.yaml
kust="$DEPLOY_DIR/kustomization.yaml"
jq -n \
  --arg api "kustomize.config.k8s.io/v1beta1" \
  --arg kind "Kustomization" \
  --argjson resources '["hello-world.src.yaml"]' \
  --argjson patches "$patches" \
  '{apiVersion: $api, kind: $kind, resources: $resources, patches: $patches}' \
  > "$kust"

# Render via kubectl kustomize
out="$DEPLOY_DIR/hello-world.yaml"
rm -f "$out"
"$KUBECTL" kustomize "$DEPLOY_DIR" > "$out.tmp" || { rm -f "$out.tmp"; die "kustomize localization failed"; }
mv "$out.tmp" "$out"

# Guard: placeholder must not survive rendering
grep -qF "$IMAGE_PLACEHOLDER" "$out" && \
  { rm -f "$out"; die "IMAGE_PLACEHOLDER still present in rendered manifest (localization did not apply)"; }

# Guard: every expected image must appear in the rendered output
for img in "${expected_images[@]}"; do
  grep -qF "image: $img" "$out" || \
    { rm -f "$out"; die "expected image not found in rendered manifest: $img"; }
done

echo "Manifests rendered to $out"
