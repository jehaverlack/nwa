#!/usr/bin/env bash
# install.sh - NWA Installer Script
set -euo pipefail

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

resolve_dirs() {
  local json="$1"
  declare -A raw resolved

  while IFS='=' read -r key val; do
    raw["$key"]="$val"
  done < <(jq -r '.DIRS | to_entries[] | "\(.key)=\(.value)"' "$json")

  if [[ -z "${raw[HOME]:-}" ]]; then
    echo "ERROR: DIRS.HOME is not defined in config.json"
    exit 1
  fi

  resolved["HOME"]="${raw[HOME]/#\~/$HOME}"

  local changed=true
  while $changed; do
    changed=false
    for key in "${!raw[@]}"; do
      [[ -n "${resolved[$key]:-}" ]] && continue

      local val="${raw[$key]}"
      for rkey in "${!resolved[@]}"; do
        val="${val/$rkey/${resolved[$rkey]:-}}"
      done

      if [[ "$val" != ** ]]; then
        resolved["$key"]="$val"
        changed=true
      fi
    done
  done

  for key in "${!raw[@]}"; do
    [[ -z "${resolved[$key]:-}" ]] && {
      echo "ERROR: Unresolved DIR: $key=${raw[$key]}"
      exit 1
    }
  done

  for key in "${!resolved[@]}"; do
    export "$key=${resolved[$key]}"
    printf "  %-12s %s\n" "$key:" "${resolved[$key]}"
    mkdir -p "${resolved[$key]}"
  done
}

use_systemd() {
  # Check if systemd user mode is available and service exists
  if systemctl --user status >/dev/null 2>&1; then
    return 0  # Use systemd
  fi
  return 1  # Use manual scripts
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

# ------------------------------------------------------------
# Require non root user
# ------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "ERROR: install.sh must be run as a non-root user"
  exit 1
fi

# ------------------------------------------------------------
# Requirements
# ------------------------------------------------------------
for cmd in awk curl grep jq nc sed sha256sum tar unzip; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is required"
    exit 1
  }
done

# ------------------------------------------------------------
# Resolve ROOT
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR" && pwd)"

CONFIG_FILE="$ROOT/config.json"
META_FILE="$ROOT/metadata.json"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config.json not found"; exit 1; }
[[ -f "$META_FILE" ]]   || { echo "ERROR: metadata.json not found"; exit 1; }

# ------------------------------------------------------------
# Hostname detection
# ------------------------------------------------------------
HOSTNAME="$(hostname)"

# ------------------------------------------------------------
# OS / platform detection
# ------------------------------------------------------------
OS_ID="unknown"
OS_LIKE=""
OS_NAME=""
OS_VERSION=""
OS_FAMILY="unknown"
OS_ARCH="unknown"
OS_PLATFORM="unknown"

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_NAME="${NAME:-unknown}"
  OS_VERSION="${VERSION_ID:-}"
fi

case "$OS_ID" in
  debian|ubuntu|raspbian|zorin)
    OS_FAMILY="debian"
    OS_PLATFORM="linux"
    ;;
  rhel|rocky|almalinux|centos|fedora)
    OS_FAMILY="rhel"
    OS_PLATFORM="linux"
    ;;
  *)
    if [[ "$OS_LIKE" == *debian* ]]; then
      OS_FAMILY="debian"
    elif [[ "$OS_LIKE" == *rhel* ]]; then
      OS_FAMILY="rhel"
    fi
    ;;
esac

# ------------------------------------------------------------
# CPU architecture detection
# ------------------------------------------------------------
ARCH_RAW="$(uname -m)"

case "$ARCH_RAW" in
  x86_64) OS_ARCH="x64" ;;
  aarch64|arm64) OS_ARCH="arm64" ;;
  armv7l) OS_ARCH="armv7l" ;;
  *)
    echo "ERROR: Unsupported architecture: $ARCH_RAW"
    exit 1
    ;;
esac

PLATFORM="${OS_FAMILY}:${OS_ARCH}"


# ------------------------------------------------------------
# SELinux detection (warn-only)
# ------------------------------------------------------------
SELINUX_MODE="disabled"

if command -v getenforce >/dev/null 2>&1; then
  SELINUX_MODE="$(getenforce | tr '[:upper:]' '[:lower:]')"
fi


# ------------------------------------------------------------
# Setting variables
# ------------------------------------------------------------

VERSION="$(jq -r '.METADATA.version' "$META_FILE")"
VERSION_DATE="$(jq -r '.METADATA.version_date' "$META_FILE")"
COPYRIGHT="$(jq -r '.METADATA.copyright' "$META_FILE")"
AUTHOR="$(jq -r '.METADATA.author' "$META_FILE")"
LICENSE="$(jq -r '.METADATA.license' "$META_FILE")"
HOMEPAGE="$(jq -r '.METADATA.homepage' "$META_FILE")"
REPO="$(jq -r '.METADATA.git_repo' "$META_FILE")"


# ------------------------------------------------------------
# NodeJS detection
# ------------------------------------------------------------
NODE_VERSION="$(jq -r '.NODEJS.VERSION' "$CONFIG_FILE")"
NODE_PLATFORMS="$(jq -r '.NODEJS.TARGETS[]' "$CONFIG_FILE" | tr '\n' ' ')"
NODE_PLATFORMS="${NODE_PLATFORMS%% }"


echo "####################################"
echo "Node Web App (NWA)"
echo "####################################"
echo "  Version:      $VERSION"
echo "  Version Date: $VERSION_DATE"
echo "  Copyright:    (C) $COPYRIGHT"
echo "  Author:       $AUTHOR"
echo "  License:      $LICENSE"
echo "  Homepage:     $HOMEPAGE"
echo "  Repository:   $REPO"
echo ""

echo "NodeJS:"
echo "  Version:      $NODE_VERSION"
echo "  Platforms:   " 
for np in $NODE_PLATFORMS; do
  echo "    $np"
done
echo ""

echo "Target System:"
echo "  Hostname:  $HOSTNAME"
echo "  OS:        $OS_NAME $OS_VERSION"
echo "  Family:    $OS_FAMILY"
echo "  Platform:  $OS_PLATFORM"
echo "  Arch:      $OS_ARCH"
echo "  systemd:   user services available"
echo "  SELinux:   $SELINUX_MODE"
echo ""

if [[ "$OS_PLATFORM" == "win32" ]]; then
  echo "ERROR: win32 host install not supported by this installer"
  exit 1
fi

echo "Directories:"
echo "  ROOT:    $ROOT"
resolve_dirs "$CONFIG_FILE"


# ------------------------------------------------------------
# Build sdl-mgr tarball to DIST
# Always rebuild sdl-mgr_version.tgz from source
# ------------------------------------------------------------
echo ""
echo "Generating: $DIST/sdl-mgr_$VERSION.tgz"
tar -czf "$DIST/sdl-mgr_$VERSION.tgz" -C "$ROOT" sdl-mgr
sha256sum "$DIST/sdl-mgr_$VERSION.tgz"  | awk '{sub(".*/","",$2); print}' > "$DIST/sdl-mgr_$VERSION.tgz.sha256"

# ------------------------------------------------------------
# Build sdl-wkr tarball to DIST
# Always rebuild sdl-wkr_version.tgz from source
# ------------------------------------------------------------
echo ""
echo "Generating: $DIST/sdl-wkr_$VERSION.tgz"
tar -czf "$DIST/sdl-wkr_$VERSION.tgz" -C "$ROOT" sdl-wkr
sha256sum "$DIST/sdl-wkr_$VERSION.tgz"  | awk '{sub(".*/","",$2); print}' > "$DIST/sdl-wkr_$VERSION.tgz.sha256"

# ------------------------------------------------------------
# Copy install-sdl-wkr.sh to DIST
# ------------------------------------------------------------
echo ""
echo "Copying: $DIST/install-sdl-wkr.sh"
cp "$ROOT/sdl-wkr/scripts/install-sdl-wkr.sh" "$DIST/install-sdl-wkr.sh"
sha256sum "$DIST/install-sdl-wkr.sh" | awk '{sub(".*/","",$2); print}' > "$DIST/install-sdl-wkr.sh.sha256"

# ------------------------------------------------------------
# Fetch NodeJS Tarballs / Zips to DIST
# ------------------------------------------------------------
echo ""
echo "Fetching NodeJS Binaries to $DIST"
SHASUM_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
curl -sSL "$SHASUM_URL" -o "$DIST/NODE_SHASUMS256.txt"

# Download NodeJS tarball

for np in $NODE_PLATFORMS; do
  IFS=":" read -r OS ARCH <<< "$np"

  case "$OS" in
    linux)   EXT="tar.xz" ;;
    darwin)  EXT="tar.gz" ;;
    win)   EXT="zip" ;;
    *) echo "ERROR: Unknown NodeJS target OS: $OS"; exit 1 ;;
  esac

  PLATFORM="${OS}-${ARCH}"
  NODE_DIR="node-v${NODE_VERSION}-${PLATFORM}"
  NODE_TARBALL="${NODE_DIR}.$EXT"
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"

  echo "  $np: $NODE_TARBALL"

  if [ ! -e "$DIST/$NODE_TARBALL" ]; then

    curl -sSL "$NODE_URL" -o "$DIST/$NODE_TARBALL"

    EXPECTED_SHA="$(grep " $NODE_TARBALL\$" "$DIST/NODE_SHASUMS256.txt" | awk '{print $1}')"

    if [[ -z "$EXPECTED_SHA" ]]; then
        echo "Error: SHA256 not found for $NODE_TARBALL"
        exit 1
    fi

    ACTUAL_SHA="$(sha256sum "$DIST/$NODE_TARBALL" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        echo "SHA mismatch $NODE_TARBALL"
        rm -f "$DIST/$NODE_TARBALL"
        exit 1
    fi

    echo "$EXPECTED_SHA  $NODE_TARBALL" > "$DIST/$NODE_TARBALL.sha256"
  fi
done

unset OS ARCH


# ------------------------------------------------------------
# Extract sdl-mgr-VERSION tarball from DIST to MGR
# Symlink to MGR/current
# ------------------------------------------------------------
echo ""
echo "Extracting: $DIST/sdl-mgr_$VERSION.tgz to $MGR/sdl-mgr_$VERSION"
rm -rf "$MGR/sdl-mgr_$VERSION"
tar -xzf "$DIST/sdl-mgr_$VERSION.tgz" -C "$MGR"
mv "$MGR/sdl-mgr" "$MGR/sdl-mgr_$VERSION"
# rm "$MGR/current"
ln -sfn "$MGR/sdl-mgr_$VERSION" "$MGR/current"

# ------------------------------------------------------------
# Copy MGR/current/conf/efault-sdl-mgr-config.json to CONF/sdl-mgr-config.json
# ------------------------------------------------------------

if [ ! -e "$CONF/sdl-mgr-config.json" ]; then
    echo ""
    echo "Copying: $MGR/current/conf/default-sdl-mgr-config.json to $CONF/sdl-mgr-config.json"
    cp "$MGR/current/conf/default-sdl-mgr-config.json" "$CONF/sdl-mgr-config.json"
fi

# ------------------------------------------------------------
# Extract NodeJS tarball from DIST to NODEJS
# Symlink to NODEJS/current
# ------------------------------------------------------------

# Check if NodeJS is already installed
NODE_BIN="$NODEJS/current/bin/node"
NPM_BIN="$NODEJS/current/bin/npm"
# echo "NodeJS binary: $NODE_BIN"

if [ -e "$NODE_BIN" ]; then
    NODE_BIN_VERSION="$("$NODE_BIN" --version)"
    # echo "NodeJS bin version: $NODE_BIN_VERSION"
    # echo "NodeJS version: v$NODE_VERSION"
    case "$OS_PLATFORM" in
      linux)  EXT="tar.xz"; TAR_OPTS="-xJf" ;;
      darwin) EXT="tar.gz"; TAR_OPTS="-xzf" ;;
      win)  EXT="zip" ;;
      *) echo "ERROR: Unsupported OS platform: $OS_PLATFORM"; exit 1 ;;
    esac

    if [ "$NODE_BIN_VERSION" != "v$NODE_VERSION" ]; then
        echo ""
        echo "Installing NodeJS: node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}"
    
        echo "Extracting: $DIST/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}.$EXT"
        if [ $OS_PLATFORM == "win32" ]; then
          echo "ERROR: win32 host install not supported by this installer"
          exit 1
          # unzip "$DIST/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}.$EXT" -d "$NODEJS"
        else 
          tar $TAR_OPTS "$DIST/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}.$EXT" -C "$NODEJS"
        fi
        # rm "$NODEJS/current"
        ln -sfn "$NODEJS/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}" "$NODEJS/current"
    else
        echo ""
        echo "NodeJS $OS_PLATFORM-$OS_ARCH v$NODE_VERSION already installed"
    fi
else
    echo ""
    echo "Installing NodeJS $NODE_VERSION"
    
    echo "Extracting: $DIST/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}.tar.xz"
    tar -xJf "$DIST/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}.tar.xz" -C "$NODEJS"
    ln -sfn "$NODEJS/node-v${NODE_VERSION}-${OS_PLATFORM}-${OS_ARCH}" "$NODEJS/current"
fi


# ------------------------------------------------------------
# Install sdl-mgr Node Dependencies
# ------------------------------------------------------------
echo ""
echo "Installing NodeJS Dependencies"
cd "$MGR/current/app"
export PATH="$NODEJS/current/bin:$PATH"
$NPM_BIN install


# ------------------------------------------------------------
# Copy Start / Stop Scripts
# ------------------------------------------------------------
mkdir -p "$HOME/scripts/"
cp "$MGR/current/scripts/start-sdl-mgr.sh" "$HOME/scripts/"
cp "$MGR/current/scripts/stop-sdl-mgr.sh" "$HOME/scripts/"
cp "$MGR/current/scripts/status-sdl-mgr.sh" "$HOME/scripts/"
chmod u+x "$HOME/scripts/"*


# ------------------------------------------------------------
# Install Systemd Unit Files
# Copy MGR/current/scripts/sdl-mgr.service to ~/.config/systemd/user
# ------------------------------------------------------------
if use_systemd; then
  echo ""
  echo "Installing SystemD Unit Files"

  mkdir -p ~/.config/systemd/user
  cp "$MGR/current/scripts/sdl-mgr.service" ~/.config/systemd/user/

  "${HOME}/scripts/stop-sdl-mgr.sh"
  sleep 1
  systemctl --user daemon-reload --no-pager
fi


# ------------------------------------------------------------
# Start SDL Manager
# ------------------------------------------------------------
"${HOME}/scripts/start-sdl-mgr.sh"
sleep 2
"${HOME}/scripts/status-sdl-mgr.sh"

if [ $? -ne 0 ]; then
  echo ""
  echo "ERROR: SDL Manager failed to start"
  exit 1
fi


# 


echo ""
echo "SDL Manager deployed:"
echo "  to: $HOME"

