# n8n Backup and Upgrade Script

Automates the backup and upgrade process for n8n installations managed via npm and systemd.

## Features

- Creates timestamped backups before every upgrade
- Supports upgrading to latest or a specific version
- Rollback to any previous backup
- Optional cleanup of old backups (7 or 30 days)
- Health checks to verify n8n is running after upgrade

## What Gets Backed Up

| Item | Location | Backup File |
|------|----------|-------------|
| n8n node_modules | `$(npm root -g)/n8n` | `n8n-node-modules.tar.gz` |
| n8n user data | `~/.n8n` | `n8n-data.tar.gz` |
| systemd unit file | varies | `systemd/` directory |
| systemd drop-ins | `/etc/systemd/system/n8n.service.d/` | `systemd/n8n.service.d/` |
| Version info | - | `version-info.txt` |
| Upgrade log | - | `upgrade.log` |

Backups are stored in `./n8n_backup/<timestamp>/`

## Prerequisites

- Root access (sudo)
- n8n installed globally via npm
- n8n running as a systemd service named `n8n.service`
- Node.js and npm in PATH

## Usage

```bash
# Make executable (first time only)
chmod +x n8n_upgrade_latest.sh

# Upgrade to latest version
sudo ./n8n_upgrade_latest.sh

# Upgrade to a specific version
sudo ./n8n_upgrade_latest.sh 1.70.0

# Rollback to a previous backup
sudo ./n8n_upgrade_latest.sh --rollback 20240115-120000

# Show help
./n8n_upgrade_latest.sh --help
```

## Rollback

To rollback to a previous version:

1. List available backups:
   ```bash
   ls ./n8n_backup/
   ```

2. Run rollback with the timestamp:
   ```bash
   sudo ./n8n_upgrade_latest.sh --rollback <TIMESTAMP>
   ```

The rollback will:
- Show the version info from the backup
- Ask for confirmation before proceeding
- Optionally restore user data (`~/.n8n`)
- Optionally restore systemd configuration

## Configuration

The script uses sensible defaults but can be customized via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `N8N_PORT` | `5678` | Port for health check endpoint |

## Troubleshooting

**n8n fails to start after upgrade:**
```bash
# Check service logs
journalctl -u n8n.service -n 50

# Rollback to previous version
sudo ./n8n_upgrade_latest.sh --rollback <TIMESTAMP>
```

**Health check warning but service is running:**
- n8n may use a non-default port - set `N8N_PORT` environment variable
- n8n may still be initializing - wait and check manually:
  ```bash
  curl http://localhost:5678/healthz
  ```
