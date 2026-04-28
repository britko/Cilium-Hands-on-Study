#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-cilium-study}"
CONFIG_PATH="${CONFIG_PATH:-labs/kind/kind-cilium.yaml}"

usage() {
  cat <<'EOF'
Usage: create-kind-cluster.sh [--cluster-name NAME] [--config PATH]

Environment variables:
  CLUSTER_NAME  kind cluster name. Default: cilium-study
  CONFIG_PATH   kind config path. Default: labs/kind/kind-cilium.yaml
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found in PATH." >&2
    exit 1
  fi
}

require_command kind
require_command kubectl
require_command docker

if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_PATH"
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME"
kubectl get nodes -o wide
