#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# n8n_upgrade_latest.sh
#
# Upgrades n8n to the latest (or specified) version from npm.
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
#
# Usage:
#   ./n8n_upgrade_latest.sh [VERSION]           # Upgrade to VERSION (default: latest)
#   ./n8n_upgrade_latest.sh --rollback <TIMESTAMP>  # Rollback to a previous backup
#
###############################################################################

############################
# CONFIG
############################
SERVICE_NAME="n8n.service"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HEALTH_CHECK_PORT="${N8N_PORT:-5678}"
HEALTH_CHECK_TIMEOUT=30

# Resolve binaries explicitly
NPM_BIN="$(command -v npm)"
NODE_BIN="$(command -v node)"

# Dynamic global modules path
NPM_GLOBAL_PATH="$($NPM_BIN root -g)"

# Backup root (relative to where script is executed)
BACKUP_ROOT="$(pwd)/n8n_backup"

############################
# FUNCTIONS
############################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [VERSION]

Upgrade n8n to the specified version (default: latest).

Options:
  --rollback <TIMESTAMP>   Rollback to a previous backup
  --help                   Show this help message

Arguments:
  VERSION                  n8n version to install (default: latest)

Examples:
  $0                       # Upgrade to latest
  $0 1.70.0                # Upgrade to specific version
  $0 --rollback 20240115-120000  # Rollback to backup from that timestamp
EOF
  exit 0
}

cleanup_old_backups() {
  local days="$1"
  local cutoff_date
  cutoff_date=$(date -d "-${days} days" +%Y%m%d)

  echo "Looking for backups older than $days days..."

  local deleted_count=0
  for dir in "$BACKUP_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    local dir_name
    dir_name=$(basename "$dir")
    # Extract date portion (YYYYMMDD) from timestamp format YYYYMMDD-HHMMSS
    local dir_date="${dir_name%%-*}"

    if [[ "$dir_date" =~ ^[0-9]{8}$ ]] && [[ "$dir_date" < "$cutoff_date" ]]; then
      echo "  Removing old backup: $dir_name"
      rm -rf "$dir"
      ((deleted_count++))
    fi
  done

  if [[ $deleted_count -eq 0 ]]; then
    echo "  No old backups found to remove."
  else
    echo "  Removed $deleted_count old backup(s)."
  fi
}

prompt_backup_cleanup() {
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    return
  fi

  local backup_count
  backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

  if [[ $backup_count -lt 2 ]]; then
    return
  fi

  echo ""
  echo "You have $backup_count existing backups."
  echo "Would you like to clean up old backups?"
  echo "  1) Remove backups older than 7 days"
  echo "  2) Remove backups older than 30 days"
  echo "  3) Skip cleanup"
  echo ""
  read -r -p "Enter choice [1-3]: " choice

  case "$choice" in
    1) cleanup_old_backups 7 ;;
    2) cleanup_old_backups 30 ;;
    3|"") echo "Skipping backup cleanup." ;;
    *) echo "Invalid choice. Skipping cleanup." ;;
  esac
  echo ""
}

do_rollback() {
  local rollback_timestamp="$1"
  local rollback_dir="$BACKUP_ROOT/$rollback_timestamp"

  if [[ ! -d "$rollback_dir" ]]; then
    echo "ERROR: Backup directory not found: $rollback_dir"
    echo ""
    echo "Available backups:"
    ls -1 "$BACKUP_ROOT" 2>/dev/null || echo "  (none)"
    exit 1
  fi

  echo "===== n8n rollback started at $(date) ====="
  echo "Restoring from: $rollback_dir"

  # Check required backup files exist
  if [[ ! -f "$rollback_dir/n8n-node-modules.tar.gz" ]]; then
    echo "ERROR: n8n-node-modules.tar.gz not found in backup."
    exit 1
  fi

  # Show version info from backup
  if [[ -f "$rollback_dir/version-info.txt" ]]; then
    echo ""
    echo "Backup version info:"
    cat "$rollback_dir/version-info.txt"
    echo ""
  fi

  read -r -p "Proceed with rollback? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Rollback cancelled."
    exit 0
  fi

  # Stop service
  echo "Stopping n8n service..."
  systemctl stop "$SERVICE_NAME"

  # Remove current installation
  echo "Removing current n8n installation..."
  $NPM_BIN uninstall -g n8n || true
  rm -rf "$NPM_GLOBAL_PATH/n8n"
  rm -rf "$NPM_GLOBAL_PATH/.n8n-*"

  # Restore node_modules
  echo "Restoring n8n from backup..."
  tar xzf "$rollback_dir/n8n-node-modules.tar.gz" -C /

  # Optionally restore user data
  if [[ -f "$rollback_dir/n8n-data.tar.gz" ]]; then
    read -r -p "Restore n8n user data (~/.n8n)? This will overwrite current data! [y/N]: " restore_data
    if [[ "$restore_data" =~ ^[Yy]$ ]]; then
      echo "Restoring n8n user data..."
      tar xzf "$rollback_dir/n8n-data.tar.gz" -C /
    fi
  fi

  # Restore systemd configs if they exist
  if [[ -d "$rollback_dir/systemd" ]]; then
    read -r -p "Restore systemd service configuration? [y/N]: " restore_systemd
    if [[ "$restore_systemd" =~ ^[Yy]$ ]]; then
      echo "Restoring systemd configuration..."
      local unit_path
      unit_path="$(systemctl show -p FragmentPath --value "$SERVICE_NAME")"

      # Restore main unit file if backup exists
      local unit_filename
      unit_filename=$(basename "$unit_path")
      if [[ -f "$rollback_dir/systemd/$unit_filename" ]]; then
        cp "$rollback_dir/systemd/$unit_filename" "$unit_path"
      fi

      # Restore drop-ins if they exist
      if [[ -d "$rollback_dir/systemd/${SERVICE_NAME}.d" ]]; then
        cp -r "$rollback_dir/systemd/${SERVICE_NAME}.d" "/etc/systemd/system/"
      fi
    fi
  fi

  # Verify installation
  if ! command -v n8n >/dev/null; then
    echo "ERROR: n8n binary not found after rollback."
    exit 1
  fi

  echo "Rolled back to n8n version: $(n8n --version)"

  # Start service
  echo "Starting n8n service..."
  systemctl daemon-reload
  systemctl start "$SERVICE_NAME"

  # Health check
  perform_health_check

  echo "===== n8n rollback completed successfully at $(date) ====="
  exit 0
}

perform_health_check() {
  echo "Performing health check..."

  # First check: is the systemd service running?
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "ERROR: n8n service failed to start."
    echo "Inspect logs with:"
    echo "  journalctl -u $SERVICE_NAME"
    exit 1
  fi
  echo "  Service is running."

  # Second check: wait for n8n to respond to requests
  echo "  Waiting for n8n to be ready (up to ${HEALTH_CHECK_TIMEOUT}s)..."
  local ready=false
  for ((i=1; i<=HEALTH_CHECK_TIMEOUT; i++)); do
    if curl -sf "http://localhost:${HEALTH_CHECK_PORT}/healthz" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done

  if [[ "$ready" == true ]]; then
    echo "  n8n is responding to requests."
  else
    echo "  WARNING: n8n service is running but not responding on port ${HEALTH_CHECK_PORT}."
    echo "  This may be normal if n8n is still initializing or uses a different port."
    echo "  Check manually: curl http://localhost:${HEALTH_CHECK_PORT}/healthz"
  fi
}

############################
# ARGUMENT PARSING
############################
VERSION="latest"
ROLLBACK_TIMESTAMP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollback)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --rollback requires a timestamp argument."
        exit 1
      fi
      ROLLBACK_TIMESTAMP="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "ERROR: Unknown option: $1"
      usage
      ;;
    *)
      VERSION="$1"
      shift
      ;;
  esac
done

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
# ROLLBACK MODE
############################
if [[ -n "$ROLLBACK_TIMESTAMP" ]]; then
  do_rollback "$ROLLBACK_TIMESTAMP"
fi

############################
# UPGRADE MODE
############################
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
LOG_FILE="$BACKUP_DIR/upgrade.log"

# Setup logging
mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== n8n upgrade to '$VERSION' started at $(date) ====="
echo "Backup directory: $BACKUP_DIR"
echo "Global npm path: $NPM_GLOBAL_PATH"

############################
# BACKUP CLEANUP PROMPT
############################
prompt_backup_cleanup

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
if [[ -d "$NPM_GLOBAL_PATH/n8n" ]]; then
  echo "Backing up global n8n installation..."
  tar czf "$BACKUP_DIR/n8n-node-modules.tar.gz" \
    "$NPM_GLOBAL_PATH/n8n"
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

rm -rf "$NPM_GLOBAL_PATH/n8n"
rm -rf "$NPM_GLOBAL_PATH/.n8n-*"

############################
# INSTALL n8n
############################
echo "Installing n8n@$VERSION from npm..."
$NPM_BIN install -g "n8n@$VERSION"

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

############################
# HEALTH CHECK
############################
perform_health_check

echo "===== n8n upgrade to '$VERSION' completed successfully at $(date) ====="
