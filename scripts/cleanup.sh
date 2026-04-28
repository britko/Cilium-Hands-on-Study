#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAMES=("$@")
if [[ ${#CLUSTER_NAMES[@]} -eq 0 ]]; then
  CLUSTER_NAMES=("cilium-study" "cilium-study-kpr")
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "Required command 'kind' was not found in PATH." >&2
  exit 1
fi

existing_clusters="$(kind get clusters)"
for cluster in "${CLUSTER_NAMES[@]}"; do
  if grep -Fxq "$cluster" <<<"$existing_clusters"; then
    kind delete cluster --name "$cluster"
  else
    echo "kind cluster '$cluster' does not exist. Skipping."
  fi
done
