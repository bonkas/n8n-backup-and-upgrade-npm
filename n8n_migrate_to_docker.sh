#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# n8n_migrate_to_docker.sh
#
# Migrates a systemd + global-npm n8n install to Docker Compose.
#
# What it does:
#   1. Reads the n8n.service unit (User, Environment, EnvironmentFile)
#   2. Stops n8n and backs up the data folder + unit definition
#   3. Copies the data folder (database.sqlite, config w/ encryption key,
#      binaryData, nodes) into /opt/n8n/n8n_data
#   4. Writes /opt/n8n/docker-compose.yml and /opt/n8n/.env
#      (pinned to the SAME n8n version you run today)
#   5. Disables the systemd service (does NOT uninstall npm n8n -> rollback)
#   6. Starts the container and health-checks it
#
# Upgrade to 3.x afterwards by changing N8N_IMAGE_TAG in /opt/n8n/.env and
# running: docker compose pull && docker compose up -d
#
# Missing requirements (curl, Docker Engine, compose plugin) are installed
# after a confirmation prompt; set ASSUME_YES=1 to skip the prompt.
#
# Usage: sudo ./n8n_migrate_to_docker.sh
#        sudo ASSUME_YES=1 ./n8n_migrate_to_docker.sh
###############################################################################

SERVICE_NAME="n8n.service"
TARGET_DIR="${TARGET_DIR:-/opt/n8n}"
HOST_PORT="${HOST_PORT:-5678}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$(pwd)/n8n_backup/migrate-$TIMESTAMP"
IMAGE="docker.n8n.io/n8nio/n8n"

mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$BACKUP_DIR/migrate.log") 2>&1
echo "===== n8n -> Docker migration started $(date) ====="

############################
# PRE-FLIGHT
############################
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)."; exit 1; }
command -v n8n >/dev/null || { echo "ERROR: n8n not found in PATH."; exit 1; }

# --- Install missing requirements (curl, Docker Engine, compose plugin) ---
install_pkgs() {
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null;   then dnf install -y -q "$@"
  elif command -v yum >/dev/null;   then yum install -y -q "$@"
  elif command -v zypper >/dev/null; then zypper --non-interactive install "$@"
  else echo "ERROR: no supported package manager found; install $* manually."; exit 1
  fi
}

NEED=()
command -v curl >/dev/null || NEED+=(curl)
command -v docker >/dev/null || NEED+=(docker)
if command -v docker >/dev/null && ! docker compose version >/dev/null 2>&1; then
  NEED+=(docker-compose-plugin)
fi

if (( ${#NEED[@]} )); then
  echo "Missing requirements: ${NEED[*]}"
  if [[ "${ASSUME_YES:-}" != "1" ]]; then
    read -r -p "Install them now? (docker uses Docker's official get.docker.com script) [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborting: requirements not met."; exit 1; }
  fi

  if [[ " ${NEED[*]} " == *" curl "* ]]; then install_pkgs curl; fi

  if [[ " ${NEED[*]} " == *" docker "* ]]; then
    # Official Docker convenience script: installs Engine + compose plugin
    # on Debian/Ubuntu/RHEL-family/Fedora. Downloaded to a file first so it can be inspected.
    GET_DOCKER="$BACKUP_DIR/get-docker.sh"
    curl -fsSL https://get.docker.com -o "$GET_DOCKER"
    sh "$GET_DOCKER"
  elif [[ " ${NEED[*]} " == *" docker-compose-plugin "* ]]; then
    install_pkgs docker-compose-plugin
  fi

  systemctl enable --now docker
fi

docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' still unavailable after install."; exit 1; }
systemctl is-active --quiet docker || systemctl start docker
[[ ! -e "$TARGET_DIR/docker-compose.yml" ]] || { echo "ERROR: $TARGET_DIR/docker-compose.yml already exists."; exit 1; }

N8N_VERSION="$(n8n --version)"
echo "Current n8n version: $N8N_VERSION"

############################
# READ THE SYSTEMD UNIT
############################
SVC_USER="$(systemctl show -p User --value "$SERVICE_NAME")"
SVC_USER="${SVC_USER:-root}"
SVC_HOME="$(getent passwd "$SVC_USER" | cut -d: -f6)"
echo "Service runs as: $SVC_USER (home: $SVC_HOME)"

# Collect environment: Environment= lines + EnvironmentFile= contents
ENV_RAW="$BACKUP_DIR/service-env.raw"
: > "$ENV_RAW"
# Environment= (systemd shell-style quoting: split on spaces, one VAR=val each)
systemctl show -p Environment --value "$SERVICE_NAME" | xargs -n1 2>/dev/null >> "$ENV_RAW" || true
# EnvironmentFile= (strip leading '-' optional marker and trailing options)
for f in $(systemctl show -p EnvironmentFiles --value "$SERVICE_NAME" | awk '{print $1}'); do
  f="${f#-}"
  [[ -f "$f" ]] && grep -Ev '^\s*(#|$)' "$f" >> "$ENV_RAW" || true
done

get_env() { grep -E "^$1=" "$ENV_RAW" | tail -n1 | cut -d= -f2- || true; }

# Data folder: N8N_USER_FOLDER/.n8n if set, else <home>/.n8n
USER_FOLDER="$(get_env N8N_USER_FOLDER)"
if [[ -n "$USER_FOLDER" ]]; then DATA_DIR="$USER_FOLDER/.n8n"; else DATA_DIR="$SVC_HOME/.n8n"; fi
[[ -d "$DATA_DIR" ]] || { echo "ERROR: data dir $DATA_DIR not found."; exit 1; }
echo "n8n data folder: $DATA_DIR"

DB_TYPE="$(get_env DB_TYPE)"
DB_TYPE="${DB_TYPE:-sqlite}"
echo "Database type: $DB_TYPE"
if [[ "$DB_TYPE" == "postgresdb" ]]; then
  PGHOST="$(get_env DB_POSTGRESDB_HOST)"
  if [[ "$PGHOST" =~ ^(localhost|127\.0\.0\.1|::1)$ || -z "$PGHOST" ]]; then
    echo "WARNING: Postgres host is '$PGHOST' (the host machine)."
    echo "         Inside the container that must be reachable as 'host.docker.internal'."
    echo "         This script adds that mapping and rewrites the host in .env."
  fi
fi

# Encryption key: env var wins, else the one in the config file
ENC_KEY="$(get_env N8N_ENCRYPTION_KEY)"
if [[ -z "$ENC_KEY" && -f "$DATA_DIR/config" ]]; then
  ENC_KEY="$(sed -n 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DATA_DIR/config" | head -n1)"
fi
[[ -n "$ENC_KEY" ]] || { echo "ERROR: could not determine the encryption key. Aborting."; exit 1; }
echo "Encryption key located (not printed)."

############################
# STOP + BACKUP
############################
echo "Stopping $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME"

echo "Backing up unit definition and data..."
systemctl cat "$SERVICE_NAME" > "$BACKUP_DIR/${SERVICE_NAME}.merged.conf"
tar czf "$BACKUP_DIR/n8n-data.tar.gz" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
cp "$ENV_RAW" "$BACKUP_DIR/service-env.backup"
chmod 600 "$BACKUP_DIR/service-env.backup" "$BACKUP_DIR/n8n-data.tar.gz"
echo "n8n version: $N8N_VERSION" > "$BACKUP_DIR/version-info.txt"

############################
# BUILD DOCKER DEPLOYMENT
############################
mkdir -p "$TARGET_DIR"
cp -a "$DATA_DIR" "$TARGET_DIR/n8n_data"
# 'node' user inside the official image is uid/gid 1000
chown -R 1000:1000 "$TARGET_DIR/n8n_data"

# .env: version pin + the service's N8N_/DB_/WEBHOOK_/GENERIC_/TZ vars
{
  echo "N8N_IMAGE_TAG=$N8N_VERSION"
  echo "N8N_ENCRYPTION_KEY=$ENC_KEY"
  grep -E '^(N8N_|DB_|WEBHOOK_URL|GENERIC_TIMEZONE|TZ|EXECUTIONS_|QUEUE_|NODE_FUNCTION_ALLOW|VUE_APP_)' "$ENV_RAW" \
    | grep -Ev '^(N8N_ENCRYPTION_KEY|N8N_USER_FOLDER|N8N_IMAGE_TAG)=' || true
} > "$TARGET_DIR/.env"

# Rewrite loopback Postgres host for the container
if [[ "$DB_TYPE" == "postgresdb" ]]; then
  sed -i -E 's/^(DB_POSTGRESDB_HOST)=(localhost|127\.0\.0\.1|::1)$/\1=host.docker.internal/' "$TARGET_DIR/.env"
fi
chmod 600 "$TARGET_DIR/.env"

cat > "$TARGET_DIR/docker-compose.yml" <<EOF
services:
  n8n:
    image: ${IMAGE}:\${N8N_IMAGE_TAG}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:5678"
    env_file: .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

############################
# DISABLE SYSTEMD, START DOCKER
############################
echo "Disabling $SERVICE_NAME (npm install left in place for rollback)..."
systemctl disable "$SERVICE_NAME"

echo "Starting container..."
cd "$TARGET_DIR"
docker compose pull
docker compose up -d

############################
# HEALTH CHECK
############################
echo "Waiting for n8n to become healthy..."
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}/healthz" >/dev/null 2>&1; then
    echo "SUCCESS: n8n $N8N_VERSION is running in Docker on port $HOST_PORT."
    echo
    echo "Next steps:"
    echo "  1. Log in and check workflows, credentials and webhooks."
    echo "  2. Upgrade: edit N8N_IMAGE_TAG in $TARGET_DIR/.env, then"
    echo "       cd $TARGET_DIR && docker compose pull && docker compose up -d"
    echo "     (read the 3.0 breaking-changes page first)."
    echo "  Rollback: docker compose -f $TARGET_DIR/docker-compose.yml down;"
    echo "            systemctl enable --now $SERVICE_NAME"
    exit 0
  fi
  sleep 2
done

echo "ERROR: n8n did not become healthy. Inspect: docker compose -f $TARGET_DIR/docker-compose.yml logs"
echo "Rollback: docker compose -f $TARGET_DIR/docker-compose.yml down; systemctl enable --now $SERVICE_NAME"
exit 1
