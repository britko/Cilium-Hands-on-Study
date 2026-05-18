#!/usr/bin/env bash

INSTALL_BASHRC=false
INSTALL_ZSHRC=false
SHOW_HELP=false

if [[ -n "${BASH_VERSION:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]}"
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    SCRIPT_IS_EXECUTED=true
  else
    SCRIPT_IS_EXECUTED=false
  fi
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  SCRIPT_PATH="${(%):-%x}"
  if [[ "${ZSH_EVAL_CONTEXT:-}" == *":file"* ]]; then
    SCRIPT_IS_EXECUTED=false
  else
    SCRIPT_IS_EXECUTED=true
  fi
else
  echo "Unsupported shell. Use bash or zsh." >&2
  return 1 2>/dev/null || exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  source scripts/use-local-tools.sh
  bash scripts/use-local-tools.sh --install-bashrc
  bash scripts/use-local-tools.sh --install-zshrc

Options:
  --install-bashrc  Add this project's local tool setup to ~/.bashrc.
  --install-zshrc   Add this project's local tool setup to ~/.zshrc.
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-bashrc)
      INSTALL_BASHRC=true
      shift
      ;;
    --install-zshrc)
      INSTALL_ZSHRC=true
      shift
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
        exit 1
      else
        return 1
      fi
      ;;
  esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
  usage
  if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
    exit 0
  else
    return 0
  fi
fi

script_dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tool_dir="$repo_root/tools/bin"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows host shells are not supported. Use WSL2 Ubuntu and run this script there." >&2
    if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
      exit 1
    else
      return 1
    fi
    ;;
esac

install_shell_rc() {
  local rc_file="$1"
  local tmp_file
  local begin_marker="# >>> cilium-hands-on-study local tools >>>"
  local end_marker="# <<< cilium-hands-on-study local tools <<<"

  touch "$rc_file"
  tmp_file="$(mktemp)"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$rc_file" > "$tmp_file"

  cat "$tmp_file" > "$rc_file"
  rm -f "$tmp_file"

  {
    echo ""
    echo "$begin_marker"
    echo "# Added by Cilium Hands-on Study. Loads local CLIs and kubectl alias/completion."
    echo "if [ -f \"$script_dir/use-local-tools.sh\" ]; then"
    echo "  source \"$script_dir/use-local-tools.sh\" >/dev/null 2>&1 || true"
    echo "fi"
    echo "$end_marker"
  } >> "$rc_file"

  echo "Installed local tool setup into $rc_file"
  echo "Open a new shell or run: source $rc_file"
}

if [[ "$INSTALL_BASHRC" == "true" ]]; then
  install_shell_rc "${HOME}/.bashrc"
  if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
    exit 0
  fi
fi

if [[ "$INSTALL_ZSHRC" == "true" ]]; then
  install_shell_rc "${HOME}/.zshrc"
  if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
    exit 0
  fi
fi

if [[ "$SCRIPT_IS_EXECUTED" == "true" ]]; then
  echo "Run this script with: source scripts/use-local-tools.sh" >&2
  echo "To persist it, run: bash scripts/use-local-tools.sh --install-bashrc or --install-zshrc" >&2
  exit 1
fi

if [[ ! -d "$tool_dir" ]]; then
  echo "Local tools directory was not found: $tool_dir. Run bash scripts/create-kind-cluster.sh or install CLIs per the OS environment docs first." >&2
  return 1
fi

case ":$PATH:" in
  *":$tool_dir:"*) ;;
  *) export PATH="$tool_dir:$PATH" ;;
esac

if command -v kubectl >/dev/null 2>&1; then
  alias k=kubectl

  if [[ -n "${BASH_VERSION:-}" ]] && command -v complete >/dev/null 2>&1; then
    source <(kubectl completion bash)
    complete -o default -F __start_kubectl k 2>/dev/null || true
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz compinit
    compinit
    source <(kubectl completion zsh)
  fi

  echo "Configured kubectl alias and completion: k=kubectl"
else
  echo "kubectl was not found in PATH. Run bash scripts/create-kind-cluster.sh first." >&2
fi

echo "Added local tools to this shell session: $tool_dir"
