#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-cilium-study}"
CONFIG_PATH="${CONFIG_PATH:-labs/kind/kind-cilium.yaml}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a}"
KIND_VERSION="${KIND_VERSION:-v0.30.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.34.0}"
TOOLS_DIR="${TOOLS_DIR:-tools/bin}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows host shells are not supported. Use WSL2 Ubuntu and run this script there." >&2
    exit 1
    ;;
esac

usage() {
  cat <<'EOF'
Usage: create-kind-cluster.sh [--cluster-name NAME] [--config PATH] [--image IMAGE] [--kind-version VERSION] [--kubectl-version VERSION] [--tools-dir PATH]

Environment variables:
  CLUSTER_NAME  kind cluster name. Default: cilium-study
  CONFIG_PATH   kind config path. Default: labs/kind/kind-cilium.yaml
  NODE_IMAGE    kind node image. Default: kindest/node:v1.34.0
  KIND_VERSION  kind CLI version to auto-install if missing. Default: v0.30.0
  KUBECTL_VERSION  kubectl CLI version to auto-install if missing. Default: v1.34.0
  TOOLS_DIR     Local CLI install directory. Default: tools/bin
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
    --image)
      NODE_IMAGE="$2"
      shift 2
      ;;
    --kind-version)
      KIND_VERSION="$2"
      shift 2
      ;;
    --kubectl-version)
      KUBECTL_VERSION="$2"
      shift 2
      ;;
    --tools-dir)
      TOOLS_DIR="$2"
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

platform_name() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "darwin" ;;
    *)
      echo "Unsupported OS: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

platform_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

resolve_tools_dir() {
  if [[ "$TOOLS_DIR" = /* ]]; then
    echo "$TOOLS_DIR"
  else
    echo "$PWD/$TOOLS_DIR"
  fi
}

normalize_version() {
  local version="$1"
  if [[ "$version" != v* ]]; then
    version="v$version"
  fi
  echo "$version"
}

ensure_kind() {
  local tool_dir
  local platform
  local arch
  local download_url

  tool_dir="$(resolve_tools_dir)"
  mkdir -p "$tool_dir"
  export PATH="$tool_dir:$PATH"

  if command -v kind >/dev/null 2>&1; then
    return
  fi

  require_command curl

  platform="$(platform_name)"
  arch="$(platform_arch)"
  download_url="https://kind.sigs.k8s.io/dl/$(normalize_version "$KIND_VERSION")/kind-$platform-$arch"

  echo "Installing kind from $download_url"
  curl -fsSL "$download_url" -o "$tool_dir/kind"
  chmod +x "$tool_dir/kind"

  if ! command -v kind >/dev/null 2>&1; then
    echo "Failed to install 'kind' into $tool_dir." >&2
    exit 1
  fi
}

ensure_kubectl() {
  local tool_dir
  local platform
  local arch
  local download_url

  tool_dir="$(resolve_tools_dir)"
  mkdir -p "$tool_dir"
  export PATH="$tool_dir:$PATH"

  if command -v kubectl >/dev/null 2>&1; then
    return
  fi

  require_command curl

  platform="$(platform_name)"
  arch="$(platform_arch)"
  download_url="https://dl.k8s.io/release/$(normalize_version "$KUBECTL_VERSION")/bin/$platform/$arch/kubectl"

  echo "Installing kubectl from $download_url"
  curl -fsSL "$download_url" -o "$tool_dir/kubectl"
  chmod +x "$tool_dir/kubectl"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Failed to install 'kubectl' into $tool_dir." >&2
    exit 1
  fi
}

ensure_kind
ensure_kubectl
require_command docker
unset KIND_EXPERIMENTAL_PROVIDER
echo "Using kind provider: docker"

if kind get clusters | grep -Fxq "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  echo "Using kind node image: $NODE_IMAGE"
  kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_PATH" --image "$NODE_IMAGE"
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME"
kubectl get nodes -o wide
