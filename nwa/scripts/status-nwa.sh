#!/usr/bin/env bash
# status-nwa.sh - Script to show status of NWA
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
  systemctl --user status nwa
else
  # Get nwa PID
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

  # Get process uptime
  PROCESS_START=$(ps -p "$NWA_PID" -o lstart= 2>/dev/null || echo "unknown")

  echo "NWA is running"
  echo "  PID:     ${NWA_PID}"
  echo "  Started: ${PROCESS_START}"
  exit 0
fi