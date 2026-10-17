#!/usr/bin/env bash
# OCM credential system helpers for OCI registry publishing.
# Source this file; it defines functions only.
set -euo pipefail

# registry_endpoint <ocm_repo>
#   Strips optional type prefix (e.g. "oci::", "oci::http://") and scheme,
#   then splits host and port. Prints two lines: host, port (port may be empty).
#   OCM_REGISTRY_HOST overrides the derived host and clears the port.
registry_endpoint() {
  local repo="$1" hostport host port
  # strip type:: prefix
  repo="${repo#*::}"
  # strip scheme://
  repo="${repo#*://}"
  # take the authority (up to first /)
  hostport="${repo%%/*}"
  # split host and port
  if [[ "$hostport" == *:* ]]; then
    host="${hostport%:*}"
    port="${hostport##*:}"
  else
    host="$hostport"
    port=""
  fi
  if [[ -n "${OCM_REGISTRY_HOST:-}" ]]; then
    [[ "$OCM_REGISTRY_HOST" != *$'\n'* ]] || die "OCM_REGISTRY_HOST must not contain a newline"
    host="$OCM_REGISTRY_HOST"
    port=""
  fi
  [[ -n "$host" ]] || die "cannot derive registry hostname from OCM_REPO='$1'"
  printf '%s\n%s\n' "$host" "$port"
}

# yaml_squote <value>
#   Emits the value wrapped in YAML single quotes (escaping embedded single
#   quotes by doubling them). Dies if the value contains a newline.
yaml_squote() {
  local v="$1"
  [[ "$v" != *$'\n'* ]] || die "credential value must not contain a newline"
  printf "'%s'" "${v//\'/\'\'}"
}

# render_registry_ocmconfig
#   Requires OCM_REGISTRY_USERNAME and OCM_REGISTRY_PASSWORD.
#   Requires OCM_REPO (to derive the consumer identity).
#   Prints an OCM generic config to stdout with:
#     - one OCIRegistry consumer (hostname [+ port]) → OCICredentials/v1
#     - one DockerConfig/v1 repository fallback
render_registry_ocmconfig() {
  [[ -n "${OCM_REGISTRY_USERNAME:-}" ]] || die "OCM_REGISTRY_USERNAME is required for registry credential publishing"
  [[ -n "${OCM_REGISTRY_PASSWORD:-}" ]] || die "OCM_REGISTRY_PASSWORD is required for registry credential publishing"
  local ep host port
  ep="$(registry_endpoint "${OCM_REPO:-}")"
  # $(...) strips the trailing newline of an empty port, so tail -1 would repeat the host
  host="$(sed -n 1p <<< "$ep")"
  port="$(sed -n 2p <<< "$ep")"
  # port is emitted bare inside double quotes, so only digits are safe
  [[ "$port" =~ ^[0-9]*$ ]] || die "registry port must be numeric, got '$port'"

  local hostq portline user pass
  hostq="$(yaml_squote "$host")"
  if [[ -n "$port" ]]; then
    portline=$'\n          '"port: \"$port\""
  else
    portline=""
  fi
  user="$(yaml_squote "$OCM_REGISTRY_USERNAME")"
  pass="$(yaml_squote "$OCM_REGISTRY_PASSWORD")"

  cat <<YAML
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      # OCIRegistry: the direct consumer match for the publish target.
      # Direct consumers take precedence over the DockerConfig fallback below.
      - identity:
          type: OCIRegistry
          hostname: ${hostq}${portline}
        credentials:
          - type: OCICredentials/v1
            username: ${user}
            password: ${pass}
    repositories:
      # DockerConfig fallback: used for any registry not matched above
      # (e.g. docker.io for --copy-resources).
      - repository:
          type: DockerConfig/v1
YAML
}
