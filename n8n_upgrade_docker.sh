#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# n8n_upgrade_docker.sh
#
# Upgrades (or rolls back) an n8n Docker Compose deployment created by
# n8n_migrate_to_docker.sh (default location: /opt/n8n).
#
# Usage:
#   sudo ./n8n_upgrade_docker.sh VERSION            # e.g. 2.48.0
#   sudo ./n8n_upgrade_docker.sh latest             # resolve the newest image tag
#   sudo ./n8n_upgrade_docker.sh --rollback <TIMESTAMP>
#   ./n8n_upgrade_docker.sh --help
#
# What an upgrade does:
#   1. Reads the current version (N8N_IMAGE_TAG in .env)
#   2. Warns and asks before a MAJOR version jump (e.g. 2.x -> 3.x)
#   3. Stops n8n and backs up data folder, .env, compose file and any
#      Dockerfile/requirements files to ./n8n_backup/docker-<timestamp>/
#      (stopped first so the SQLite file is consistent)
#   4. Sets the new N8N_IMAGE_TAG, pulls (or rebuilds a custom image)
#   5. Starts n8n and health-checks it
#   6. On failure offers to roll back automatically (config AND data -
#      newer versions migrate the database, so old data must be restored)
#
# Variables: TARGET_DIR (default /opt/n8n), ASSUME_YES=1 (skip prompts, and
# roll back automatically on failure).
###############################################################################

TARGET_DIR="${TARGET_DIR:-/opt/n8n}"
IMAGE="docker.n8n.io/n8nio/n8n"
BACKUP_ROOT="$(pwd)/n8n_backup"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HEALTH_TRIES=45   # x 2s

usage() { sed -n '4,28p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {  # confirm "question"  -> 0 if yes
  [[ "${ASSUME_YES:-}" == "1" ]] && return 0
  local ans; read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

env_get() { grep -E "^$1=" "$TARGET_DIR/.env" | tail -n1 | cut -d= -f2- | sed -E "s/^'(.*)'\$/\1/; s/^\"(.*)\"\$/\1/" || true; }

uses_build() { grep -Eq '^[[:space:]]+build:' "$TARGET_DIR/docker-compose.yml"; }

wait_healthy() {
  local cport port i
  cport="$(env_get N8N_PORT)"; cport="${cport:-5678}"
  port="$(docker compose port n8n "$cport" 2>/dev/null | awk -F: '{print $NF}')"
  port="${port:-5678}"
  for i in $(seq 1 "$HEALTH_TRIES"); do
    if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

apply_images() {  # pull or build for the tag currently in .env
  if uses_build; then docker compose build --pull; else docker compose pull; fi
}

# Restore config + data from a backup dir and start the old version.
restore_from() {
  local dir="$1"
  echo "Stopping n8n..."
  docker compose stop n8n || true
  echo "Restoring configuration..."
  cp -f "$dir/.env" "$TARGET_DIR/.env"
  cp -f "$dir/docker-compose.yml" "$TARGET_DIR/docker-compose.yml"
  for f in "$dir"/Dockerfile* "$dir"/requirements*.txt; do
    [[ -f "$f" ]] && cp -f "$f" "$TARGET_DIR/"
  done
  echo "Restoring data (replaces current n8n_data)..."
  rm -rf "$TARGET_DIR/n8n_data"
  tar xzf "$dir/n8n-data.tar.gz" -C "$TARGET_DIR"
  chown -R 1000:1000 "$TARGET_DIR/n8n_data"
  echo "Starting restored version $(env_get N8N_IMAGE_TAG)..."
  if uses_build; then docker compose up -d --build; else docker compose up -d; fi
  if wait_healthy; then
    echo "SUCCESS: rolled back to $(env_get N8N_IMAGE_TAG) and healthy."
  else
    echo "ERROR: restored instance not healthy. Inspect: docker compose -f $TARGET_DIR/docker-compose.yml logs"
    return 1
  fi
}

############################
# ARGUMENTS
############################
MODE="upgrade"; ARG=""
case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  --rollback)   MODE="rollback"; ARG="${2:-}"; [[ -n "$ARG" ]] || { echo "ERROR: --rollback needs a TIMESTAMP"; ls -1 "$BACKUP_ROOT" 2>/dev/null | grep '^docker-' || true; exit 1; } ;;
  *)            ARG="$1" ;;
esac

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)."; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not installed."; exit 1; }
[[ -f "$TARGET_DIR/docker-compose.yml" && -f "$TARGET_DIR/.env" ]] \
  || { echo "ERROR: no deployment found in $TARGET_DIR (set TARGET_DIR=...)."; exit 1; }
cd "$TARGET_DIR"

############################
# ROLLBACK
############################
if [[ "$MODE" == "rollback" ]]; then
  DIR="$BACKUP_ROOT/${ARG#docker-}"
  [[ -d "$DIR" ]] || DIR="$BACKUP_ROOT/docker-${ARG#docker-}"
  if [[ ! -d "$DIR" ]]; then
    echo "ERROR: backup not found: $DIR"; echo "Available:"; ls -1 "$BACKUP_ROOT" 2>/dev/null | grep '^docker-' || echo "  (none)"; exit 1
  fi
  echo "===== n8n rollback from $DIR ====="
  cat "$DIR/version-info.txt" 2>/dev/null || true
  confirm "Restore this backup? Current data in $TARGET_DIR/n8n_data will be REPLACED." || { echo "Cancelled."; exit 0; }
  restore_from "$DIR"
  exit $?
fi

############################
# UPGRADE
############################
CURRENT="$(env_get N8N_IMAGE_TAG)"
[[ -n "$CURRENT" ]] || { echo "ERROR: N8N_IMAGE_TAG not found in $TARGET_DIR/.env"; exit 1; }

if [[ "$ARG" == "latest" ]]; then
  echo "Resolving latest n8n version (pulling $IMAGE:latest)..."
  docker pull -q "$IMAGE:latest" >/dev/null
  NEW="$(docker run --rm --entrypoint n8n "$IMAGE:latest" --version 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: could not determine the latest version automatically. Pass an explicit VERSION."; exit 1; }
else
  NEW="${ARG#v}"
  [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: VERSION must look like 2.48.0 (got '$ARG')."; exit 1; }
fi

BACKUP_DIR="$BACKUP_ROOT/docker-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
exec > >(tee -a "$BACKUP_DIR/upgrade.log") 2>&1
echo "===== n8n Docker upgrade started $(date) ====="
echo "Current: $CURRENT   Target: $NEW"

if [[ "$CURRENT" == "$NEW" ]]; then
  echo "Already on $NEW. Nothing to do."; exit 0
fi

CUR_MAJOR="${CURRENT%%.*}"; NEW_MAJOR="${NEW%%.*}"
if [[ "$NEW_MAJOR" -gt "$CUR_MAJOR" ]]; then
  echo
  echo "WARNING: major version jump ($CUR_MAJOR.x -> $NEW_MAJOR.x). Read the breaking changes first:"
  echo "         https://docs.n8n.io/changelog/v${NEW_MAJOR}0-breaking-changes"
  echo "         (removed nodes, changed defaults, removed env vars can break workflows)"
  confirm "Continue with the major upgrade?" || { echo "Cancelled."; exit 0; }
elif [[ "$NEW_MAJOR" -lt "$CUR_MAJOR" ]]; then
  echo "ERROR: $NEW is older than $CURRENT. Use --rollback with a backup instead (data may not be downgrade-safe)."
  exit 1
fi

# Fetch/build the new image BEFORE stopping n8n, so a bad tag costs no downtime.
echo "Preparing new image..."
cp .env "$BACKUP_DIR/.env.pre"   # temp copy so we can restore .env if the pull fails
sed -i -E "s/^N8N_IMAGE_TAG=.*/N8N_IMAGE_TAG=$NEW/" .env
if ! apply_images; then
  echo "ERROR: could not pull/build $NEW (does that tag exist?). Nothing was changed."
  cp -f "$BACKUP_DIR/.env.pre" .env; rm -f "$BACKUP_DIR/.env.pre"
  exit 1
fi
cp -f "$BACKUP_DIR/.env.pre" .env; rm -f "$BACKUP_DIR/.env.pre"

echo "Stopping n8n and backing up..."
docker compose stop n8n
cp .env docker-compose.yml "$BACKUP_DIR/"
for f in Dockerfile* requirements*.txt; do [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/"; done
tar czf "$BACKUP_DIR/n8n-data.tar.gz" -C "$TARGET_DIR" n8n_data
chmod 600 "$BACKUP_DIR/n8n-data.tar.gz" "$BACKUP_DIR/.env"
echo "version before upgrade: $CURRENT" > "$BACKUP_DIR/version-info.txt"
echo "Backup: $BACKUP_DIR"

echo "Switching to $NEW and starting..."
sed -i -E "s/^N8N_IMAGE_TAG=.*/N8N_IMAGE_TAG=$NEW/" .env
if uses_build; then docker compose up -d --build; else docker compose up -d; fi

if wait_healthy; then
  RUNNING="$(docker exec n8n n8n --version 2>/dev/null | tr -d '[:space:]' || true)"
  echo "SUCCESS: n8n is healthy (running: ${RUNNING:-unknown}, requested: $NEW)."
  echo "Log in and check workflows, credentials and webhooks."
  echo "Roll back if needed:  sudo ./n8n_upgrade_docker.sh --rollback ${BACKUP_DIR##*/docker-}"
  echo "Old images stay on disk; reclaim space later with: docker image prune"
  echo "===== completed $(date) ====="
  exit 0
fi

echo "ERROR: n8n did not become healthy on $NEW."
echo "Logs: docker compose -f $TARGET_DIR/docker-compose.yml logs --tail 100 n8n"
if confirm "Roll back to $CURRENT (config and data) now?"; then
  restore_from "$BACKUP_DIR"
else
  echo "Not rolled back. Manual rollback: sudo ./n8n_upgrade_docker.sh --rollback ${BACKUP_DIR##*/docker-}"
fi
exit 1
