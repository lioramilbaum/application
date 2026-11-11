#!/usr/bin/env bash
# Bootstrap bundle layout, shared by scripts/sourcectl.sh (writes the bundle) and scripts/targetctl.sh
# (reads it). Source this file after lib.sh; it defines variables and functions only.
set -euo pipefail

# Directory the bundle is written to and read from. sourcectl.sh deletes and rebuilds it, so it must be under BUILD_DIR
BOOTSTRAP_BUNDLE_DIR="${BOOTSTRAP_BUNDLE_DIR:-$BUILD_DIR/bootstrap-bundle}"
# Files a complete bundle holds, relative to $BOOTSTRAP_BUNDLE_DIR. images.txt lists the node images; each one
# has an archive at $(_image_archive REF), which _missing_bundle_file also checks.
BOOTSTRAP_BUNDLE_FILES=(ctf charts/ocm-k8s-toolkit.tgz charts/kro.tgz flux/install.yaml images.txt images/registry.tar public.pem)
# Same digest pin as scripts/registry.sh (test/run.sh checks that the two match)
# shellcheck disable=SC2034
BOOTSTRAP_REGISTRY_IMAGE="${BOOTSTRAP_REGISTRY_IMAGE:-registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373}"
# Host-side name of the registry image in images/registry.tar, one tag per platform: <ref>-amd64 and <ref>-arm64.
# A local name never clashes with a registry:2 the host already has.
# shellcheck disable=SC2034
BOOTSTRAP_REGISTRY_LOCAL_REF="ocm-bootstrap/registry:sha256-${BOOTSTRAP_REGISTRY_IMAGE##*@sha256:}"
# Platforms the image archives keep. The rest of each upstream index is pruned (scripts/sourcectl.sh).
# shellcheck disable=SC2034
BOOTSTRAP_IMAGE_ARCHES=(amd64 arm64)
# OCM config that verifies the bundle CTF with the bundled public key. Written by sourcectl.sh and targetctl.sh
# shellcheck disable=SC2034
BOOTSTRAP_VERIFY_CONFIG="$BUILD_DIR/bootstrap-verify.ocmconfig"

# Prints the first bundle file that is missing, or nothing
_missing_bundle_file() {
  local f ref
  for f in "${BOOTSTRAP_BUNDLE_FILES[@]}"; do
    [[ -e "$BOOTSTRAP_BUNDLE_DIR/$f" ]] || { echo "$f"; return 0; }
  done
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    f="$(_image_archive "$ref")"
    [[ -e "$BOOTSTRAP_BUNDLE_DIR/$f" ]] || { echo "$f"; return 0; }
  done < "$BOOTSTRAP_BUNDLE_DIR/images.txt"
}

# _image_archive REF: the bundle path of the archive that holds the node image REF
_image_archive() { echo "images/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').tar"; }

# _image_repo REF: the repository of REF, without tag or digest, in the full form containerd names images by
# (registry:2 -> docker.io/library/registry, fluxcd/x -> docker.io/fluxcd/x)
_image_repo() {
  local name="${1%%@*}" first
  [[ "${name##*/}" == *:* ]] && name="${name%:*}"
  if [[ "$name" != */* ]]; then
    name="docker.io/library/$name"
  else
    first="${name%%/*}"
    [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]] || name="docker.io/$name"
  fi
  echo "$name"
}

# _image_full_ref REF: REF with its repository in the full form (registry:2@sha256:x -> docker.io/library/registry:2@sha256:x)
_image_full_ref() {
  local name="${1%%@*}" ref
  ref="$(_image_repo "$1")"
  [[ "${name##*/}" == *:* ]] && ref="$ref:${name##*:}"
  [[ "$1" == *@* ]] && ref="$ref@${1##*@}"
  echo "$ref"
}

# _image_names REF DIGEST: the names a node looks REF up by: <repo>@DIGEST, and <repo>:<tag> when REF has a tag
_image_names() {
  local name="${1%%@*}" repo
  repo="$(_image_repo "$1")"
  echo "$repo@$2"
  [[ "${name##*/}" == *:* ]] && echo "$repo:${name##*:}"
  return 0
}

bundle_ref() { echo "ctf::$BOOTSTRAP_BUNDLE_DIR/ctf//$ROOT_COMPONENT:$VERSION"; }

# _verify_config PUBLIC_KEY OUT: writes an OCM config that verifies RSA signatures made with PUBLIC_KEY
_verify_config() {
  # A JSON string is also a valid double-quoted YAML scalar, so a path with a colon, a quote or a space stays one value
  local key_yaml
  key_yaml="$(jq -n --arg p "$1" '$p')"
  cat > "$2" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $key_yaml
EOF
}
