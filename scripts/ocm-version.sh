#!/usr/bin/env bash
# OCM CLI version validation against test/ocm-versions.tsv.
#
#   bash scripts/ocm-version.sh check    exit 0 if the installed $OCM has a row, else 1
#   bash scripts/ocm-version.sh expect COLUMN
#                                        print COLUMN of the installed version's row
#
# test/run.sh sources this file for ocm_installed_version and ocm_expectation.
set -euo pipefail

OCM_DEFAULT_TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test/ocm-versions.tsv"
OCM_VERSIONS_TABLE="${OCM_VERSIONS_TABLE:-$OCM_DEFAULT_TABLE}"

# ocm_installed_version: version reported by `$OCM version`, without a leading v; empty if unknown.
ocm_installed_version() {
  local v
  v="$("${OCM:-ocm}" version 2>/dev/null | sed -n 's/^[[:space:]]*Version:[[:space:]]*//p' | head -n1 || true)"
  echo "${v#v}"
}

# ocm_expectation VERSION COLUMN: COLUMN of VERSION's row.
# Returns 1 if VERSION has no row and 2 if the table has no COLUMN.
ocm_expectation() {
  local version="$1" column="$2"
  [[ -f "$OCM_VERSIONS_TABLE" ]] || { echo "ERROR: $OCM_VERSIONS_TABLE not found" >&2; return 2; }
  awk -F'\t' -v v="$version" -v c="$column" '
    /^#/ || NF == 0 { next }
    !h { for (i = 1; i <= NF; i++) if ($i == c) col = i; h = 1; if (!col) exit 2; next }
    v != "" && $1 == v { print $col; found = 1; exit }
    END { if (!h || !col) exit 2; exit !found }
  ' "$OCM_VERSIONS_TABLE"
}

# ocm_validated_versions: every version with a row, one per line.
ocm_validated_versions() {
  awk -F'\t' '/^#/ || NF == 0 { next } !h { h = 1; next } { print $1 }' "$OCM_VERSIONS_TABLE"
}

_check() {
  local v label="test/ocm-versions.tsv" note=""
  [[ "$OCM_VERSIONS_TABLE" == "$OCM_DEFAULT_TABLE" ]] || note="; table: $OCM_VERSIONS_TABLE"
  v="$(ocm_installed_version)"
  if [[ -n "$v" ]] && ocm_expectation "$v" version >/dev/null; then
    echo "OCM ${v} is validated (${label}${note})"
    return 0
  fi
  local msg="OCM ${v:-<unknown version>} not validated: add expectations to ${label}${note} (see docs/development.md#ocm-version-validation)"
  [[ "${GITHUB_ACTIONS:-}" == true ]] && echo "::error title=ocm-version-validated::${msg}"
  echo "ERROR: ${msg}" >&2
  echo "Validated versions: $(ocm_validated_versions | paste -sd' ' -)" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-check}" in
    check) _check ;;
    expect)
      [[ -n "${2:-}" ]] || { echo "usage: $0 expect COLUMN" >&2; exit 2; }
      ocm_expectation "$(ocm_installed_version)" "$2" ;;
    *) echo "usage: $0 [check|expect COLUMN]" >&2; exit 2 ;;
  esac
fi
