#!/usr/bin/env bash
set -euo pipefail

CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-stable}"
HUBBLE_VERSION="${HUBBLE_VERSION:-stable}"
TOOLS_DIR="${TOOLS_DIR:-tools/bin}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows host shells are not supported. Use WSL2 Ubuntu and run this script there." >&2
    exit 1
    ;;
esac

usage() {
  cat <<'EOF'
Usage: install-cilium-tools.sh [--cilium-version VERSION] [--hubble-version VERSION] [--tools-dir PATH]

Installs Cilium CLI and Hubble CLI into the project-local tools directory.

Environment variables:
  CILIUM_CLI_VERSION  Cilium CLI version. Default: stable
  HUBBLE_VERSION      Hubble CLI version. Default: stable
  TOOLS_DIR           Local CLI install directory. Default: tools/bin

Examples:
  bash scripts/install-cilium-tools.sh
  bash scripts/install-cilium-tools.sh --cilium-version v0.18.7 --hubble-version v1.2.0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cilium-version)
      CILIUM_CLI_VERSION="$2"
      shift 2
      ;;
    --hubble-version)
      HUBBLE_VERSION="$2"
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

resolve_cilium_version() {
  if [[ "$CILIUM_CLI_VERSION" == "stable" ]]; then
    curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt
  else
    normalize_version "$CILIUM_CLI_VERSION"
  fi
}

resolve_hubble_version() {
  if [[ "$HUBBLE_VERSION" == "stable" ]]; then
    curl -fsSL https://raw.githubusercontent.com/cilium/hubble/master/stable.txt
  else
    normalize_version "$HUBBLE_VERSION"
  fi
}

install_tar_tool() {
  local name="$1"
  local version="$2"
  local url="$3"
  local tool_dir="$4"
  local tmp_dir

  tmp_dir="$(mktemp -d)"

  echo "Installing $name $version from $url"
  curl -fsSL "$url" -o "$tmp_dir/$name.tar.gz"
  tar xzf "$tmp_dir/$name.tar.gz" -C "$tmp_dir"
  install "$tmp_dir/$name" "$tool_dir/$name"

  if ! "$tool_dir/$name" --help >/dev/null 2>&1; then
    echo "Failed to verify '$name' after installation into $tool_dir." >&2
    exit 1
  fi

  rm -rf "$tmp_dir"
}

main() {
  local tool_dir
  local platform
  local arch
  local cilium_version
  local hubble_version

  require_command curl
  require_command tar
  require_command install

  tool_dir="$(resolve_tools_dir)"
  mkdir -p "$tool_dir"

  platform="$(platform_name)"
  arch="$(platform_arch)"
  cilium_version="$(resolve_cilium_version)"
  hubble_version="$(resolve_hubble_version)"

  install_tar_tool \
    cilium \
    "$cilium_version" \
    "https://github.com/cilium/cilium-cli/releases/download/${cilium_version}/cilium-${platform}-${arch}.tar.gz" \
    "$tool_dir"

  install_tar_tool \
    hubble \
    "$hubble_version" \
    "https://github.com/cilium/hubble/releases/download/${hubble_version}/hubble-${platform}-${arch}.tar.gz" \
    "$tool_dir"

  echo "Installed Cilium tools into $tool_dir"
  echo "Add them to this shell with: export PATH=\"$tool_dir:\$PATH\""
}

main
