#!/usr/bin/env bash
# start-nwa.sh - Script to start Node Web App
set -euo pipefail

use_systemd() {
  # Check if systemd user mode is available and service exists
  if systemctl --user status >/dev/null 2>&1; then
    # Check if our service file exists
    if systemctl --user list-unit-files | grep -q "^nwa.service"; then
      return 0  # Use systemd
    fi
  fi
  return 1  # Use manual scripts
}

# Get $NWA_HOME directory from SCRIPT PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NWA_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

if use_systemd; then
  # Systemd mode - let systemd handle it
  echo "Starting NWA (systemd)..."
  systemctl --user start nwa
  exit 0
fi

# Manual mode - continue with checks
NODE_BIN_DIR="${NWA_HOME}/nodejs/current/bin"
NODE_BIN="${NODE_BIN_DIR}/node"
NPM_BIN="${NODE_BIN_DIR}/npm"

NWA_APP_DIR="${NWA_HOME}/current/app"

# Check that nwa is not already running
NWA_PID=""
for pid in $(pgrep -f 'node' 2>/dev/null || true); do
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null || true)
  if [[ "$cwd" == *"nwa"* ]]; then
    NWA_PID="$pid"
    break
  fi
done

if [[ -n "$NWA_PID" ]]; then
    echo "ERROR: NWA is already running with PID ${NWA_PID}"
    echo "       Stop it first: ${NWA_HOME}/scripts/stop-nwa.sh"
    exit 1
fi

# Verify paths exist
if [[ ! -f "$NODE_BIN" ]]; then
  echo "ERROR: Node.js not found at: $NODE_BIN"
  echo "       Run install.sh first"
  exit 1
fi

if [[ ! -d "$NWA_APP_DIR" ]]; then
  echo "ERROR: NWA app not found at: $NWA_APP_DIR"
  echo "       Run install.sh first"
  exit 1
fi

echo "Starting NWA..."
echo "  App Dir: ${NWA_APP_DIR}"
echo "  Node: