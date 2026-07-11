#!/usr/bin/env bash
# install.sh - NWA Installer Script
set -euo pipefail

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

resolve_dirs() {
  local json="$1"
  local sitename="$2"
  declare -A raw resolved

  if [[ -z "$sitename" || "$sitename" == "null" ]]; then
    echo "ERROR: METADATA.name is not defined in metadata.json"
    exit 1
  fi

  # Basic safety: deployment directory name should be simple.
  if [[ ! "$sitename" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: Invalid METADATA.name for deploy directory: $sitename"
    echo "       Allowed characters: A-Z a-z 0-9 . _ -"
    exit 1
  fi

  while IFS='=' read -r key val; do
    raw["$key"]="$val"
  done < <(jq -r '.DIRS | to_entries[] | "\(.key)=\(.value)"' "$json")

  # SITE is derived from metadata.json, not from deploy config.
  resolved["SITE"]="$HOME/.$sitename"

  local changed=true
  while $changed; do
    changed=false
    for key in "${!raw[@]}"; do
      [[ "$key" == "SITE" ]] && continue
      [[ -n "${resolved[$key]:-}" ]] && continue

      local val="${raw[$key]}"

      for rkey in "${!resolved[@]}"; do
        val="${val/$rkey/${resolved[$rkey]:-}}"
      done

      local unresolved=false

      for unresolved_key in "${!raw[@]}"; do
        if [[ "$unresolved_key" != "SITE" && -z "${resolved[$unresolved_key]:-}" && "$val" == *"$unresolved_key"* ]]; then
          unresolved=true
          break
        fi
      done

      if [[ "$unresolved" == false ]]; then
        resolved["$key"]="$val"
        changed=true
      fi
    done
  done

  for key in "${!raw[@]}"; do
    [[ "$key" == "SITE" ]] && continue

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


install_nodejs() {
  NODE_TARGET="${OS_PLATFORM}:${OS_ARCH}"
  NODE_PLATFORM="${OS_PLATFORM}-${OS_ARCH}"

  echo ""
  echo "Target NodeJS:"
  echo "  Target:   $NODE_TARGET"
  echo "  Platform: $NODE_PLATFORM"

  if ! jq -e --arg target "$NODE_TARGET" '.NODEJS.TARGETS[] | select(. == $target)' "$CONFIG_FILE" >/dev/null; then
    echo "ERROR: NodeJS target not listed in config: $NODE_TARGET"
    exit 1
  fi

  case "$OS_PLATFORM" in
    linux)
      EXT="tar.xz"
      TAR_OPTS="-xJf"
      ;;
    darwin)
      EXT="tar.gz"
      TAR_OPTS="-xzf"
      ;;
    win)
      echo "ERROR: win32 host install not supported by this installer"
      exit 1
      ;;
    *)
      echo "ERROR: Unsupported OS platform: $OS_PLATFORM"
      exit 1
      ;;
  esac

  NODE_DIR="node-v${NODE_VERSION}-${NODE_PLATFORM}"
  NODE_TARBALL="${NODE_DIR}.${EXT}"
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
  SHASUM_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

  NODE_BIN="$NODEJS/current/bin/node"

  if [[ -e "$NODE_BIN" ]]; then
    NODE_BIN_VERSION="$("$NODE_BIN" --version)"

    if [[ "$NODE_BIN_VERSION" == "v$NODE_VERSION" ]]; then
      echo ""
      echo "NodeJS $NODE_PLATFORM v$NODE_VERSION already installed"
      return 0
    fi
  fi

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' RETURN

  echo ""
  echo "Installing NodeJS:"
  echo "  Version:  $NODE_VERSION"
  echo "  Archive:  $NODE_TARBALL"
  echo "  To:       $NODEJS"

  curl -sSL "$SHASUM_URL" -o "$TMP_DIR/SHASUMS256.txt"
  curl -sSL "$NODE_URL" -o "$TMP_DIR/$NODE_TARBALL"

  EXPECTED_SHA="$(grep " $NODE_TARBALL\$" "$TMP_DIR/SHASUMS256.txt" | awk '{print $1}')"

  if [[ -z "$EXPECTED_SHA" ]]; then
    echo "ERROR: SHA256 not found for $NODE_TARBALL"
    exit 1
  fi

  ACTUAL_SHA="$(sha256sum "$TMP_DIR/$NODE_TARBALL" | awk '{print $1}')"

  if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "ERROR: SHA mismatch for $NODE_TARBALL"
    exit 1
  fi

  rm -rf "$NODEJS/$NODE_DIR"
  tar $TAR_OPTS "$TMP_DIR/$NODE_TARBALL" -C "$NODEJS"

  ln -sfn "$NODEJS/$NODE_DIR" "$NODEJS/current"

  echo "NodeJS installed:"
  echo "  $NODEJS/current/bin/node"
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

CONFIG_FILE="$ROOT/nwa-deploy-config.json"
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
SITENAME="$(jq -r '.METADATA.name' "$META_FILE")"
PROJECT="$(jq -r '.METADATA.project' "$META_FILE")"
DESCRIPTION="$(jq -r '.METADATA.description // .METADATA.name' "$META_FILE")"
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
echo "  Sitename:     $SITENAME"
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
echo "  ROOT:        $ROOT"
# resolve_dirs "$CONFIG_FILE"
resolve_dirs "$CONFIG_FILE" "$SITENAME"

# ------------------------------------------------------------
# Copy nwa to Prod Dir
# ------------------------------------------------------------
echo ""
echo "Installing nwa version $VERSION to $VERSIONS/nwa_$VERSION"
rsync -av $ROOT/nwa --exclude='node_modules' $VERSIONS/nwa_$VERSION
# ln -s $VERSIONS/nwa_$VERSION $VERSIONS/current
ln -sfnT "$VERSIONS/nwa_$VERSION" "$VERSIONS/current"
NWA="$VERSIONS/current/nwa"

# ------------------------------------------------------------
# Fetch NodeJS Tarballs / Zips to DIST
# ------------------------------------------------------------
install_nodejs

unset OS ARCH

# ------------------------------------------------------------
# Copy NWA/current/conf/default-nwa-config.json to CONF/nwa-config.json
# ------------------------------------------------------------

if [ ! -e "$CONF/nwa-config.json" ]; then
    echo ""
    echo "Copying: $NWA/conf/nwa-config.json to $CONF/nwa-config.json"
    rsync -av "$NWA/conf/nwa-config.json" "$CONF/nwa-config.json"

    echo "Updating site metadata in $CONF/nwa-config.json"

    tmp_config="$(mktemp)"
    jq \
      --arg id "$SITENAME" \
      --arg name "$PROJECT" \
      --arg desc "$DESCRIPTION" \
      '
      .site.id = $id
      | .site.name = $name
      | .site.desc = $desc
      ' "$CONF/nwa-config.json" > "$tmp_config"

    mv "$tmp_config" "$CONF/nwa-config.json"
fi

# ------------------------------------------------------------
# Extract NodeJS tarball from DIST to NODEJS
# Symlink to NODEJS/current
# ------------------------------------------------------------

# # Check if NodeJS is already installed
NODE_BIN="$NODEJS/current/bin/node"
NPM_BIN="$NODEJS/current/bin/npm"
# echo "NodeJS binary: $NODE_BIN"


# ------------------------------------------------------------
# Install nwa Node Dependencies
# ------------------------------------------------------------
echo ""
echo "Installing NodeJS Dependencies"
cd "$NWA/app"
export PATH="$NODEJS/current/bin:$PATH"
$NPM_BIN install


# ------------------------------------------------------------
# Copy Start / Stop Scripts
# ------------------------------------------------------------
# mkdir -p "$SITE/scripts/"
# cp "$NWA/scripts/start-nwa.sh" "$SITE/scripts/"
# cp "$NWA/scripts/stop-nwa.sh" "$SITE/scripts/"
# cp "$NWA/scripts/status-nwa.sh" "$SITE/scripts/"
# chmod u+x "$SITE/scripts/"*

# ------------------------------------------------------------
# Install Systemd Unit File
# Copy SITENAME.service template to ~/.config/systemd/user/${SITENAME}.service
# ------------------------------------------------------------
if use_systemd; then
  echo ""
  echo "Installing SystemD Unit File"

  USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
  SERVICE_NAME="${SITENAME}.service"
  SERVICE_TEMPLATE="$NWA/scripts/SITENAME.service"
  SERVICE_FILE="$USER_SYSTEMD_DIR/$SERVICE_NAME"

  if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
    echo "ERROR: systemd service template not found: $SERVICE_TEMPLATE"
    exit 1
  fi

  mkdir -p "$USER_SYSTEMD_DIR"

  # Stop existing service if present
  systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  # Optional: disable old hardcoded nwa.service if this install is now metadata-named
  if [[ "$SERVICE_NAME" != "nwa.service" ]]; then
    systemctl --user stop nwa.service >/dev/null 2>&1 || true
    systemctl --user disable nwa.service >/dev/null 2>&1 || true
  fi

  # Render template
  sed \
    -e "s#SITENAME#${SITENAME}#g" \
    -e "s#PROJECT#${PROJECT}#g" \
    "$SERVICE_TEMPLATE" > "$SERVICE_FILE"

  systemctl --user daemon-reload
  systemd-analyze --user verify "$SERVICE_FILE"

  systemctl --user enable "$SERVICE_NAME"
  systemctl --user restart "$SERVICE_NAME"

  echo "Installed systemd user service:"
  echo "  $SERVICE_NAME"

  systemctl --user start "$SERVICE_NAME"
  systemctl --user --no-pager status "$SERVICE_NAME"
fi



echo ""
echo "NWA deployed:"
echo "  to: $SITE"

