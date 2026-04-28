#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-1.19.3}"
VALUES_PATH="${VALUES_PATH:-labs/01-install/cilium-values.yaml}"

usage() {
  cat <<'EOF'
Usage: install-cilium.sh [--version VERSION] [--values PATH]

Environment variables:
  VERSION      Cilium chart version. Default: 1.19.3
  VALUES_PATH  Helm values file path. Default: labs/01-install/cilium-values.yaml
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --values)
      VALUES_PATH="$2"
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

require_command helm
require_command kubectl
require_command cilium
require_command hubble

helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --version "$VERSION" \
  --namespace kube-system \
  --values "$VALUES_PATH"

cilium status --wait
cilium hubble enable --ui
hubble status
