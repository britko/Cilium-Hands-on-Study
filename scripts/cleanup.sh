#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAMES=()

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows host shells are not supported. Use WSL2 Ubuntu and run this script there." >&2
    exit 1
    ;;
esac

usage() {
  cat <<'EOF'
Usage: cleanup.sh [CLUSTER_NAME...]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      CLUSTER_NAMES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#CLUSTER_NAMES[@]} -eq 0 ]]; then
  CLUSTER_NAMES=("cilium-study" "cilium-study-kpr")
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found in PATH." >&2
    exit 1
  fi
}

require_command kind
require_command docker
unset KIND_EXPERIMENTAL_PROVIDER
echo "Using kind provider: docker"

existing_clusters="$(kind get clusters)"
for cluster in "${CLUSTER_NAMES[@]}"; do
  if grep -Fxq "$cluster" <<<"$existing_clusters"; then
    kind delete cluster --name "$cluster"
  else
    echo "kind cluster '$cluster' does not exist. Skipping."
  fi
done
