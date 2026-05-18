#!/usr/bin/env bash
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-tools/bin}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows host shells are not supported. Use WSL2 Ubuntu and run this script there." >&2
    exit 1
    ;;
esac

if [[ -d "$TOOLS_DIR" ]]; then
  export PATH="$PWD/$TOOLS_DIR:$PATH"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found in PATH." >&2
    exit 1
  fi
}

require_command kubectl
require_command cilium
require_command hubble

HUBBLE_PORT_FORWARD_PID=""
HUBBLE_PORT_FORWARD_LOG=""

cleanup() {
  if [[ -n "$HUBBLE_PORT_FORWARD_PID" ]] && kill -0 "$HUBBLE_PORT_FORWARD_PID" >/dev/null 2>&1; then
    kill "$HUBBLE_PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$HUBBLE_PORT_FORWARD_LOG" ]]; then
    rm -f "$HUBBLE_PORT_FORWARD_LOG"
  fi
}

trap cleanup EXIT

ensure_hubble_access() {
  if hubble status >/dev/null 2>&1; then
    hubble status
    return
  fi

  HUBBLE_PORT_FORWARD_LOG="$(mktemp)"
  echo "Starting Hubble Relay port-forward on 127.0.0.1:4245."
  kubectl -n kube-system port-forward svc/hubble-relay 4245:80 >"$HUBBLE_PORT_FORWARD_LOG" 2>&1 &
  HUBBLE_PORT_FORWARD_PID="$!"

  for _ in {1..20}; do
    if hubble status >/dev/null 2>&1; then
      hubble status
      return
    fi
    sleep 1
  done

  echo "Failed to connect to Hubble Relay through localhost:4245." >&2
  echo "port-forward output:" >&2
  sed 's/^/  /' "$HUBBLE_PORT_FORWARD_LOG" >&2
  exit 1
}

cilium status --wait
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay
ensure_hubble_access

echo "Running Cilium connectivity test. This may take several minutes."
cilium connectivity test
