# n8n Backup and Upgrade Script

A bash script that automates the backup and upgrade process for [n8n](https://n8n.io/) workflow automation instances installed globally via npm and managed with systemd.

> **n8n 3.0 notice:** n8n 3.0 drops npm as a supported install method (see the
> [v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes)), so the npm
> upgrade script stops being useful at 2.x. Use `n8n_migrate_to_docker.sh`
> ([details below](#migrating-to-docker-n8n-30)) to move an existing npm/systemd install to Docker Compose.

## Why This Script?

Upgrading n8n installed via npm can be error-prone. Common issues include:

- npm cache corruption causing failed upgrades
- Leftover files from previous installations causing conflicts
- Forgetting to stop the service before upgrading
- No easy way to rollback if something goes wrong
- Lost configurations after a failed upgrade

This script solves these problems by:

1. Creating a complete backup before any changes
2. Properly stopping the service and cleaning up the installation
3. Performing a clean install of the new version
4. Verifying the upgrade was successful with health checks
5. Providing an easy rollback mechanism if needed

## Features

- **Safe upgrades** - Creates timestamped backups before every upgrade
- **Version control** - Upgrade to the latest version or specify an exact version
- **Easy rollback** - Restore any previous backup with a single command
- **Backup management** - Optional cleanup of old backups (7 or 30 days)
- **Health checks** - Verifies n8n service is running and responding after upgrade
- **Complete logging** - All operations are logged for troubleshooting

## Prerequisites

Before using this script, ensure you have:

- **Linux server** with systemd (Ubuntu, Debian, CentOS, etc.)
- **Root access** (sudo privileges)
- **n8n installed globally** via npm (`npm install -g n8n`)
- **n8n running as a systemd service** named `n8n.service`
- **Node.js and npm** installed and available in PATH
- **curl** for health checks

### Verify Your Setup

```bash
# Check n8n is installed globally
n8n --version

# Check systemd service exists
systemctl status n8n.service

# Check Node.js and npm are available
node --version
npm --version
```

## Installation

1. Clone or download this repository:
   ```bash
   git clone https://github.com/bonkas/n8n-backup-and-upgrade-npm.git
   cd n8n-backup-and-upgrade-npm
   ```

2. Make the script executable:
   ```bash
   chmod +x n8n_upgrade_latest.sh
   ```

## Usage

### Upgrade to Latest Version

```bash
sudo ./n8n_upgrade_latest.sh
```

### Upgrade to a Specific Version

```bash
sudo ./n8n_upgrade_latest.sh 1.70.0
```

### Rollback to a Previous Backup

```bash
sudo ./n8n_upgrade_latest.sh --rollback 20240115-120000
```

### Show Help

```bash
./n8n_upgrade_latest.sh --help
```

## What Gets Backed Up

Each backup is stored in `./n8n_backup/<timestamp>/` and includes:

| Item | Source Location | Backup File |
|------|-----------------|-------------|
| n8n installation | `$(npm root -g)/n8n` | `n8n-node-modules.tar.gz` |
| User data & workflows | auto-detected data folder (often `~/.n8n`) | `n8n-data.tar.gz` |
| Data folder location | - | `data-dir.txt` |
| systemd unit file | varies | `systemd/<service-name>` |
| systemd merged config | - | `systemd/n8n.service.merged.conf` |
| systemd drop-ins | `/etc/systemd/system/n8n.service.d/` | `systemd/n8n.service.d/` |
| Version metadata | - | `version-info.txt` |
| Upgrade log | - | `upgrade.log` |

### Backup Directory Structure

```
n8n_backup/
└── 20240115-120000/
    ├── n8n-node-modules.tar.gz    # Complete n8n installation
    ├── n8n-data.tar.gz            # Workflows, credentials, settings
    ├── systemd/
    │   ├── n8n.service            # Original unit file
    │   ├── n8n.service.merged.conf # Full effective configuration
    │   └── n8n.service.d/         # Drop-in overrides (if any)
    ├── version-info.txt           # Node, npm, n8n versions
    └── upgrade.log                # Complete operation log
```

## How the Upgrade Process Works

1. **Pre-flight checks** - Verifies root access and required binaries
2. **Backup cleanup prompt** - Optionally remove old backups (7 or 30 days)
3. **Create backups** - Saves all n8n-related files and configurations
4. **Stop service** - Gracefully stops n8n.service
5. **Uninstall** - Removes existing n8n and cleans up leftover files
6. **Install** - Fresh install of the specified version via npm
7. **Start service** - Starts n8n.service and reloads systemd
8. **Health check** - Verifies the service is running and responding

## Rollback

If an upgrade causes problems, you can easily restore a previous version.

### List Available Backups

```bash
ls ./n8n_backup/
```

### Perform Rollback

```bash
sudo ./n8n_upgrade_latest.sh --rollback <TIMESTAMP>
```

### Rollback Process

The rollback will:
1. Display the version info from the backup
2. Ask for confirmation before proceeding
3. Stop the n8n service
4. Remove the current n8n installation
5. Restore n8n from the backup
6. Optionally restore user data to the folder recorded in `data-dir.txt` - **prompts for confirmation**
7. Optionally restore systemd configuration - **prompts for confirmation**
8. Start the service and verify health

**Note:** User data and systemd configuration restoration are optional and require explicit confirmation, as they may overwrite current configurations and workflows.

## Configuration

The script uses sensible defaults but can be customized via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `N8N_PORT` | `5678` | Port for health check endpoint |
| `DATA_DIR` | auto-detected | n8n data folder (the one containing `database.sqlite`); also honoured by `n8n_migrate_to_docker.sh` |
| `SKIP_DATA_BACKUP` | unset | Set to `1` to continue without a data backup if the folder can't be found (e.g. external DB) |

The data folder is detected from the running service (open `database.sqlite` or `N8N_USER_FOLDER`),
then from `N8N_USER_FOLDER` in the unit, then the service user's home. If it can't be found the script
**stops before touching n8n** rather than silently skipping the data backup. Find it with:

```bash
sudo find / -name database.sqlite -path '*n8n*' 2>/dev/null
```

### Example with Custom Port

```bash
sudo N8N_PORT=5680 ./n8n_upgrade_latest.sh
```

## Troubleshooting

### n8n fails to start after upgrade

```bash
# Check service logs
journalctl -u n8n.service -n 50

# Check service status
systemctl status n8n.service

# Rollback to previous version
sudo ./n8n_upgrade_latest.sh --rollback <TIMESTAMP>
```

### Health check warning but service is running

This usually means n8n is still initializing or using a non-default port:

```bash
# Check manually
curl http://localhost:5678/healthz

# If using a different port, set it:
sudo N8N_PORT=5680 ./n8n_upgrade_latest.sh
```

### Permission denied errors

Ensure you're running with sudo:

```bash
sudo ./n8n_upgrade_latest.sh
```

### npm not found

Make sure Node.js and npm are in the root user's PATH:

```bash
sudo which npm
sudo which node
```

### Backup directory fills up disk space

Use the built-in cleanup prompt, or manually remove old backups:

```bash
# List backups with sizes
du -sh ./n8n_backup/*

# Remove a specific backup
rm -rf ./n8n_backup/20240101-120000
```

## Migrating to Docker (n8n 3.0+)

`n8n_migrate_to_docker.sh` converts a global-npm + systemd install into a Docker Compose deployment.
It has **not been run against a live server yet** - test it on a snapshot or clone first.

```bash
chmod +x n8n_migrate_to_docker.sh
sudo ./n8n_migrate_to_docker.sh
```

Optional variables: `DATA_DIR` (n8n data folder), `TARGET_DIR` (default `/opt/n8n`), `HOST_PORT`
(default: the service's `N8N_PORT`, else `5678`) and `BIND_ADDR` (e.g. `127.0.0.1` to publish the port only on
the host's loopback - note Docker-published ports bypass `ufw`/`firewalld`).

### Prerequisites

- Docker, the `docker compose` plugin and `curl` - if missing, the script offers to install them
  (Docker via the official `get.docker.com` script; set `ASSUME_YES=1` to skip the prompt)
- `n8n` still installed via npm and managed by `n8n.service`

### What it does

1. Reads `n8n.service` (service user, `Environment=`, `EnvironmentFile=`), the data folder
   (including `N8N_USER_FOLDER`) and the DB type
2. Locates the encryption key (env var or `config` file) and aborts if it cannot be found
3. Stops the service and backs up the unit definition and data folder to
   `./n8n_backup/migrate-<timestamp>/`
4. Copies the data folder to `<TARGET_DIR>/n8n_data` (owned by uid/gid 1000, the container's `node` user)
5. Writes `<TARGET_DIR>/docker-compose.yml` and `.env`, pinning the image to your **current** n8n version
   and setting `N8N_ENCRYPTION_KEY` explicitly
6. Disables `n8n.service` (the npm install is left in place for rollback)
7. Starts the container and checks `/healthz`

For Postgres, the existing database is kept; a loopback `DB_POSTGRESDB_HOST` is rewritten to
`host.docker.internal`.

### After migrating

1. Verify workflows, credentials and webhooks on the same version
2. Read the 3.0 breaking changes (e.g. removed Function / Function Item nodes)
3. Change `N8N_IMAGE_TAG` in `<TARGET_DIR>/.env`, then:
   ```bash
   cd /opt/n8n && docker compose pull && docker compose up -d
   ```

The data folder is auto-detected (override with `DATA_DIR=/path/to/.n8n`). Note that inside the container n8n
runs as the unprivileged `node` user (uid 1000) rather than root, and workflows that call host binaries or
paths (e.g. Execute Command nodes) will need those mounted or baked into a custom image.

### Execute Command node

n8n 2.x disables the Execute Command node by default. If your workflows use it, add this to
`/opt/n8n/.env` and recreate the container (a container only reads `.env` when created):

```bash
echo "NODES_EXCLUDE='[]'" | sudo tee -a /opt/n8n/.env
cd /opt/n8n && sudo docker compose up -d --force-recreate
```

A malformed `NODES_EXCLUDE` in the old unit (e.g. `[ExecuteCommand]` - it must be a JSON array of full node types such as
`["n8n-nodes-base.executeCommand"]`) is dropped by the script, so n8n's default applies.

Commands run **inside the container** as the unprivileged `node` user, so host binaries, scripts and paths are not
available (see the next section).

### Optional: extra tools in the image (e.g. Python)

The official n8n image is a Docker Hardened Image (Alpine): no package manager and no Python. Anything an Execute
Command node needs (Python, extra CLIs) must be built into a custom image. This is workflow-specific, so the
migration script does not do it. `docker/` contains an **example** that adds a Python venv at `/opt/n8n-python`
(so existing `/opt/n8n-python/bin/python3 script.py` commands keep working):

- `docker/Dockerfile.n8n-python` - builds Python with `uv` in a throwaway stage and copies it onto the n8n image
- `docker/requirements-n8n-python.txt` - pip packages for the venv

> Status: verified working on n8n 2.47.3 (Python 3.13, one pure-Python package). Packages with compiled
> extensions are not tested against this image - build and test before relying on it.

```bash
cd /opt/n8n
sudo cp /path/to/repo/docker/* .
sudo docker build -f Dockerfile.n8n-python -t n8n-python:$(grep ^N8N_IMAGE_TAG .env | cut -d= -f2) .
sudo docker run --rm --entrypoint /opt/n8n-python/bin/python3 n8n-python:<tag> -c "import epicstore_api; print('ok')"
```

Then in `docker-compose.yml` replace the `image:` line with a build section and add a mount for your scripts:

```yaml
    build:
      context: .
      dockerfile: Dockerfile.n8n-python
      args:
        N8N_VERSION: ${N8N_IMAGE_TAG}
    image: n8n-python:${N8N_IMAGE_TAG}
    volumes:
      - ./n8n_data:/home/node/.n8n
      - /root/.n8n-files:/home/node/.n8n-files   # scripts the workflow runs
```

**Mount scripts under `/home/node`, not `/root`.** The container runs as the unprivileged `node` user (uid 1000) and
`/root` inside the image is mode 700, so a mount under `/root` fails with `Permission denied` whatever the host
permissions are. `/home/node/.n8n-files` is also n8n's default folder for the Read/Write Files nodes. Update the paths in
your Execute Command nodes to match (e.g. `/opt/n8n-python/bin/python3 /home/node/.n8n-files/scripts/python/script.py`),
and make the files readable by uid 1000: `sudo chmod -R a+rX /root/.n8n-files` (add `chown -R 1000:1000` if scripts write).

Apply with `sudo docker compose up -d --build`. After changing `N8N_IMAGE_TAG` for an upgrade, run the same command so the
image is rebuilt on the new version.

### Rollback

```bash
docker compose -f /opt/n8n/docker-compose.yml down
sudo systemctl enable --now n8n.service
```

### Environment variables

**Every** variable defined by the unit (`Environment=` and `EnvironmentFile=`) is copied into `.env`, including
custom ones (proxy settings, `NODES_EXCLUDE`, ...). Only host-specific ones are skipped (`PATH`, `HOME`, `USER`,
`SHELL`, `NODE_PATH`, `N8N_USER_FOLDER`, ...). Variable names are printed during the run, never values. Values are
written single-quoted so `$` in passwords isn't interpolated by Compose.

Things that can't work unchanged in a container are adjusted or listed in a **REVIEW** section (also saved to
`n8n_backup/migrate-<timestamp>/review.txt`):

| Case | What the script does |
|------|----------------------|
| `N8N_PORT` not 5678 | Container listens on it; the host port defaults to the same value |
| `N8N_LISTEN_ADDRESS` is loopback | Dropped (would make the container unreachable); use `BIND_ADDR=127.0.0.1` instead |
| `NODES_EXCLUDE` / `NODES_INCLUDE` not a valid JSON array | Dropped with a warning (n8n defaults apply) |
| `DB_POSTGRESDB_HOST` is localhost | Rewritten to `host.docker.internal` |
| Variable points at a host **file** (e.g. `NODE_EXTRA_CA_CERTS`) | Mounted read-only at the same path; must be readable by uid 1000 |
| Variable points at a host **directory** | Flagged - add a volume yourself if needed |
| Value contains `localhost` / `127.0.0.1` | Flagged - use `host.docker.internal` for host services |

The generated `docker-compose.yml` also rotates container logs (10 MB x 3).

## Security Considerations

- The script requires **root access** to manage systemd services and global npm packages
- Backups may contain **sensitive data** including workflow credentials stored in the n8n data folder
- Store backups securely and consider encrypting them if they contain sensitive workflows
- The script does not transmit any data externally

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is open source. Feel free to use, modify, and distribute as needed.
