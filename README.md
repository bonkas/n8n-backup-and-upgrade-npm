# n8n Backup and Upgrade Script

A bash script that automates the backup and upgrade process for [n8n](https://n8n.io/) workflow automation instances installed globally via npm and managed with systemd.

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
   git clone https://github.com/yourusername/n8n-backup-and-upgrade-npm.git
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
| User data & workflows | `~/.n8n` | `n8n-data.tar.gz` |
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
6. Optionally restore user data (`~/.n8n`) - **prompts for confirmation**
7. Optionally restore systemd configuration - **prompts for confirmation**
8. Start the service and verify health

**Note:** User data and systemd configuration restoration are optional and require explicit confirmation, as they may overwrite current configurations and workflows.

## Configuration

The script uses sensible defaults but can be customized via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `N8N_PORT` | `5678` | Port for health check endpoint |

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

## Security Considerations

- The script requires **root access** to manage systemd services and global npm packages
- Backups may contain **sensitive data** including workflow credentials stored in `~/.n8n`
- Store backups securely and consider encrypting them if they contain sensitive workflows
- The script does not transmit any data externally

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is open source. Feel free to use, modify, and distribute as needed.
