#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require jq awk

# No timestamp or serialNumber: same inputs → same digest → signable SBOM.

mkdir -p "$(dirname "$SBOM_FILE")"

# Parse the constructor for hello-world-* resources (skip the SBOM itself).
# Fields: name|architecture|imageReference|filePath
# Use | as separator; - for empty fields (avoids IFS=$'\t' merging empty fields).
mapfile -t rows < <(awk -v sbom="$SBOM_RESOURCE" '
  /^[[:space:]]*- name:/ { n = $NF; a = "-" }
  /^[[:space:]]*architecture:/ { a = $NF }
  /^[[:space:]]*imageReference:/ && n ~ /^hello-world-/ && n != sbom {
    print n "|" a "|" $NF "|-"
  }
  /^[[:space:]]*path:/ && n ~ /^hello-world-/ && n != sbom {
    print n "|" a "|-|" $NF
  }
' "$ROOT/component-constructor.yaml")

[[ ${#rows[@]} -gt 0 ]] || die "no hello-world-* rows found in constructor"

# Build component entries
components_json="[]"
image_count=0
file_count=0

for row in "${rows[@]}"; do
  IFS='|' read -r name arch img_ref file_path <<< "$row"

  if [[ "$img_ref" != "-" ]]; then
    # Container component: parse reference
    if [[ "$img_ref" =~ ^(.+)/([^/:@]+):([^@]+)@sha256:([0-9a-f]{64})$ ]]; then
      repo="${BASH_REMATCH[1]}"
      img_name="${BASH_REMATCH[2]}"
      tag="${BASH_REMATCH[3]}"
      digest_hex="${BASH_REMATCH[4]}"
    else
      die "imageReference does not match expected format: $img_ref"
    fi
    encoded_digest="$(printf 'sha256:%s' "$digest_hex" | jq -Rr @uri)"
    component="$(jq -cn \
      --arg name "$img_name" \
      --arg bom_ref "hello-world-image/$arch" \
      --arg version "$tag" \
      --arg digest "$digest_hex" \
      --arg purl "pkg:oci/${img_name}@${encoded_digest}?arch=${arch}&repository_url=${repo}&tag=${tag}" \
      --arg arch "$arch" \
      --arg res_name "$name" \
      '{
        type: "container",
        "bom-ref": $bom_ref,
        name: $name,
        version: $version,
        hashes: [{alg: "SHA-256", content: $digest}],
        purl: $purl,
        properties: [
          {name: "ocm:resource:name", value: $res_name},
          {name: "ocm:resource:extraIdentity:architecture", value: $arch}
        ]
      }')"
    image_count=$((image_count + 1))
  else
    # File component
    resolved="${ROOT}/${file_path#./}"
    [[ -f "$resolved" ]] || die "file not found: $resolved"
    file_hash="$(sha256 "$resolved")"
    component="$(jq -cn \
      --arg bom_ref "$name" \
      --arg path "$file_path" \
      --arg hash "$file_hash" \
      --arg res_name "$name" \
      '{
        type: "file",
        "bom-ref": $bom_ref,
        name: $path,
        hashes: [{alg: "SHA-256", content: $hash}],
        properties: [
          {name: "ocm:resource:name", value: $res_name}
        ]
      }')"
    file_count=$((file_count + 1))
  fi

  components_json="$(jq -cn --argjson arr "$components_json" --argjson c "$component" '$arr + [$c]')"
done

[[ $image_count -gt 0 ]] || die "no image components found"
[[ $file_count -gt 0 ]] || die "no file components found"

# Extract all bom-refs for dependencies
bom_refs="$(jq '[.[]["bom-ref"]]' <<< "$components_json")"

tmp_file="$SBOM_FILE.tmp.$$"
jq -cn \
  --arg root_component "$ROOT_COMPONENT" \
  --arg version "$VERSION" \
  --arg supplier "${ROOT_COMPONENT%/*}" \
  --argjson components "$components_json" \
  --argjson depends_on "$bom_refs" \
  '{
    bomFormat: "CycloneDX",
    specVersion: "1.6",
    version: 1,
    metadata: {
      tools: {components: [{type: "application", name: "scripts/sbom.sh"}]},
      component: {
        type: "application",
        "bom-ref": $root_component,
        name: $root_component,
        version: $version,
        supplier: {name: $supplier}
      }
    },
    components: $components,
    dependencies: [{ref: $root_component, dependsOn: $depends_on}]
  }' > "$tmp_file"
mv "$tmp_file" "$SBOM_FILE"
printf '%s\n' "$SBOM_FILE"
