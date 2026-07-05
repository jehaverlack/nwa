#!/usr/bin/env bash
# stop-nwa.sh - Script to stop NWA
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

if use_systemd; then
  # Systemd mode - let systemd handle it
  echo "Stopping NWA (systemd)..."
  systemctl --user stop nwa --quiet 2>/dev/null || true
  echo "NWA stopped"
  exit 0
fi

# Manual mode - find and kill process
NWA_PID=""
for pid in $(pgrep -f 'node' 2>/dev/null || true); do
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null || true)
  if [[ "$cwd" == *"nwa"* ]]; then
    NWA_PID="$pid"
    break
  fi
done

if [[ -z "$NWA_PID" ]]; then
    echo "NWA is not running"
    exit 0
fi

echo "Stopping NWA (PID: ${NWA_PID})..."

# Send SIGTERM for graceful shutdown
kill "$NWA_PID"

# Wait up to 10 seconds for process to exit
for i in {1..10}; do
  if ! kill -0 "$NWA_PID" 2>/dev/null; then
    echo "NWA stopped successfully"
    exit 0
  fi
  sleep 1
done

# If still running after 10 seconds, force kill
if kill -0 "$NWA_PID" 2>/dev/null; then
  echo "WARNING: Graceful shutdown failed, forcing kill..."
  kill -9 "$NWA_PID"
  sleep 1
  
  if kill -0 "$NWA_PID" 2>/dev/null; then
    echo "ERROR: Failed to stop NWA"
    exit 1
  fi
fi

echo "NWA stopped"