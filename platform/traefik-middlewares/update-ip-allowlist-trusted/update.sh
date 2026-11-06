#!/usr/bin/env bash
set -euo pipefail

github_ranges=$(curl -fsSL --retry 3 https://api.github.com/meta | jq -c '[.actions[] | select(contains(":") | not)]')
github_count=$(jq 'length' <<<"${github_ranges}")

if (( github_count < 100 )); then
  echo "Only ${github_count} GitHub Actions IPv4 ranges returned; leaving the Middleware unchanged" >&2
  exit 1
fi

fixed_ranges=$(grep -v -e '^\s*$' -e '^#' /config/fixed-ranges.txt | jq -Rsc 'split("\n") | map(select(length > 0))')

jq -n --argjson fixed "${fixed_ranges}" --argjson github "${github_ranges}" '{
  apiVersion: "traefik.io/v1alpha1",
  kind: "Middleware",
  metadata: {
    name: "ip-allowlist-trusted",
    namespace: "backstage",
    labels: {"bnjns.uk/owner": "backstage"}
  },
  spec: {
    ipWhiteList: {sourceRange: ($fixed + $github)}
  }
}' | kubectl apply --server-side --force-conflicts --field-manager=update-ip-allowlist-trusted -f -

echo "Applied $(jq 'length' <<<"${fixed_ranges}") fixed and ${github_count} GitHub Actions ranges"
