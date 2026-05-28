#!/usr/bin/env bash
set -euo pipefail

source_name="${1:-xanmod}"
requested_ref="${2:-auto}"

case "$source_name" in
  xanmod)
    repo="https://gitlab.com/xanmod/linux.git"
    ;;
  debian)
    repo="https://salsa.debian.org/kernel-team/linux.git"
    ;;
  *)
    echo "unsupported source: $source_name" >&2
    exit 2
    ;;
esac

if [[ "$requested_ref" == "auto" ]]; then
  if [[ "$source_name" == "xanmod" ]]; then
    resolved_ref="$((git ls-remote --heads "$repo" || true) \
      | awk '{print $2}' \
      | sed 's#refs/heads/##' \
      | grep -E '^[0-9]+([.][0-9]+)+$' \
      | sort -V \
      | tail -n 1)"
  else
    resolved_ref="debian/latest"
  fi
else
  resolved_ref="${requested_ref#refs/heads/}"
fi

if [[ -z "${resolved_ref:-}" ]]; then
  echo "unable to resolve upstream ref for $source_name" >&2
  exit 3
fi

sha="$((git ls-remote --heads "$repo" "$resolved_ref" || true) | awk '{print $1}' | head -n 1)"
if [[ -z "$sha" ]]; then
  sha="$((git ls-remote "$repo" "$resolved_ref" || true) | awk '{print $1}' | head -n 1)"
fi
if [[ -z "$sha" ]]; then
  echo "unable to resolve sha for $repo $resolved_ref" >&2
  exit 4
fi

cat <<EOF
SOURCE_NAME=$source_name
SOURCE_REPO=$repo
REQUESTED_REF=$requested_ref
RESOLVED_REF=$resolved_ref
RESOLVED_SHA=$sha
EOF

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "source_name=$source_name"
    echo "source_repo=$repo"
    echo "requested_ref=$requested_ref"
    echo "resolved_ref=$resolved_ref"
    echo "resolved_sha=$sha"
  } >> "$GITHUB_OUTPUT"
fi