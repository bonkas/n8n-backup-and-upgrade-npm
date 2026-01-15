#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# n8n_upgrade_latest.sh
#
# Upgrades n8n to the latest available version from npm.
# This script intentionally tracks `n8n@latest`.
#
# BEFORE upgrading, it creates a fully self-contained backup in:
#   ./n8n_backup/<timestamp>/
#
# Backups include:
# - systemd unit (merged + source + drop-ins)
# - global n8n node_modules
# - n8n user data (~/.n8n)
# - version metadata
# - upgrade log
###############################################################################

############################
# CONFIG
############################
SERVICE_NAME="n8n.service"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Resolve binaries explicitly
NPM_BIN="$(command -v npm)"
NODE_BIN="$(command -v node)"

# Backup root (relative to where script is executed)
BACKUP_ROOT="$(pwd)/n8n_backup"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
LOG_FILE="$BACKUP_DIR/upgrade.log"

############################
# LOGGING
############################
mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== n8n upgrade (latest) started at $(date) ====="
echo "Backup directory: $BACKUP_DIR"

############################
# PRE-FLIGHT CHECKS
############################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run as root (or via sudo)."
  exit 1
fi

if [[ -z "$NPM_BIN" || -z "$NODE_BIN" ]]; then
  echo "ERROR: node or npm not found in PATH."
  exit 1
fi

############################
# BACKUPS
############################
echo "Creating backups..."

### Systemd service backup
SYSTEMD_BACKUP_DIR="$BACKUP_DIR/systemd"
mkdir -p "$SYSTEMD_BACKUP_DIR"

echo "Backing up systemd service definition..."

# Fully merged, effective unit (critical)
systemctl cat "$SERVICE_NAME" \
  > "$SYSTEMD_BACKUP_DIR/${SERVICE_NAME}.merged.conf"

# Source unit file
UNIT_PATH="$(systemctl show -p FragmentPath --value "$SERVICE_NAME")"
if [[ -f "$UNIT_PATH" ]]; then
  cp "$UNIT_PATH" "$SYSTEMD_BACKUP_DIR/"
fi

# Drop-in overrides
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
if [[ -d "$DROPIN_DIR" ]]; then
  cp -r "$DROPIN_DIR" "$SYSTEMD_BACKUP_DIR/"
fi

### Global n8n install
if [[ -d /usr/lib/node_modules/n8n ]]; then
  echo "Backing up global n8n installation..."
  tar czf "$BACKUP_DIR/n8n-node-modules.tar.gz" \
    /usr/lib/node_modules/n8n
fi

### n8n user data
if [[ -d "$HOME/.n8n" ]]; then
  echo "Backing up n8n user data..."
  tar czf "$BACKUP_DIR/n8n-data.tar.gz" "$HOME/.n8n"
fi

### Version metadata
{
  echo "Node version: $($NODE_BIN --version)"
  echo "npm version: $($NPM_BIN --version)"
  echo "n8n version (pre-upgrade): $(n8n --version || echo 'not installed')"
} > "$BACKUP_DIR/version-info.txt"

############################
# STOP SERVICE
############################
echo "Stopping n8n service..."
systemctl stop "$SERVICE_NAME"

############################
# UNINSTALL EXISTING VERSION
############################
echo "Removing existing n8n installation..."

$NPM_BIN uninstall -g n8n || true

rm -rf /usr/lib/node_modules/n8n
rm -rf /usr/lib/node_modules/.n8n-*

############################
# INSTALL LATEST n8n
############################
echo "Installing latest n8n from npm..."
$NPM_BIN install -g n8n@latest

############################
# VERIFY INSTALL
############################
if ! command -v n8n >/dev/null; then
  echo "ERROR: n8n binary not found after installation."
  exit 1
fi

echo "Installed n8n version: $(n8n --version)"

############################
# START SERVICE
############################
echo "Starting n8n service..."
systemctl daemon-reload
systemctl start "$SERVICE_NAME"

sleep 5

############################
# HEALTH CHECK
############################
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo "SUCCESS: n8n is running."
else
  echo "ERROR: n8n failed to start."
  echo "Inspect logs with:"
  echo "  journalctl -u $SERVICE_NAME"
  exit 1
fi

echo "===== n8n upgrade (latest) completed successfully at $(date) ====="
