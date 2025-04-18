# BorgBackup System with Local Queue

This system provides encrypted, deduplicated backups with offline capability. Backups are first created locally, then automatically synced to a remote server when connectivity is available.

## System Components

1. **borg_backup.sh** - Creates local backups (falling back to local storage when offline)
2. **borg-sync-queue.sh** - Syncs local backups to remote server when online
3. **systemd services/timers** - Automates backup and sync scheduling

## Installation Guide

### 1. Prerequisites

_On both local and backup servers:_

```bash
# Install required packages
sudo apt update
sudo apt install borgbackup fuse3 sshfs
```

### 2. Setup Backup Repository

_On backup server:_

```bash
# Create repository directory (run as backup user)
mkdir -p ~/borg-repositories
borg init --encryption=repokey ~/borg-repositories/client-pc
```

This creates an encrypted repository where client backups will be stored.

### 3. Configure SSH Access

_On local machine:_

```bash
# Generate dedicated SSH key for backups
ssh-keygen -t ed25519 -f ~/.ssh/id_borg -N ""

# Copy key to backup server
ssh-copy-id -i ~/.ssh/id_borg backup-user@backup-server.example.com
```

This creates a secure connection method without password prompts.

### 4. Local Machine Setup

_On local machine:_

```bash
# Create secure directories
sudo mkdir -p /etc/borg /var/borg/local_queue /var/log/borg
sudo chmod 700 /etc/borg /var/borg/local_queue
```

### 5. Configure Backup Encryption

_On local machine:_

```bash
# Store passphrase securely (replace 'your-passphrase')
echo "your-passphrase" | sudo systemd-creds encrypt - /etc/borg/crypted_password.cred
sudo chmod 600 /etc/borg/crypted_password.cred
```

This encrypts your repository passphrase for automated access.

### 6. Install Scripts

_On local machine:_

```bash
# Copy scripts to system location
sudo cp borg_backup.sh borg-sync-queue.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/borg_*.sh

# Edit configuration (set your paths and server)
sudo nano /usr/local/bin/borg_backup.sh
```

Configure these key variables in `borg_backup.sh`:

```bash
REPOSITORY="backup-user@backup-server.example.com:borg-repositories/client-pc"
SSH_KEY="/home/local-user/.ssh/id_borg"
BACKUP_PATHS="/etc /home /var/www"
```

### 7. Install Systemd Services

_On local machine:_

```bash
# Copy service files
sudo cp *.service *.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload
```

## Service Configuration

### Backup Schedule

_On local machine:_

```bash
# Enable daily backup at 2AM with random delay
sudo systemctl enable --now borg-backup.timer

# Enable hourly sync attempts
sudo systemctl enable --now borg-sync.timer
```

### Verify Operation

_On local machine:_

```bash
# Check service status
systemctl list-timers --all | grep borg

# View logs
journalctl -u borg-backup -u borg-sync -f
```

## Backup Management

### List Available Backups

_On local machine (local queue):_

```bash
borg list /var/borg/local_queue
```

_On local machine (remote repository):_

```bash
borg list backup-user@backup-server.example.com:borg-repositories/client-pc
```

### Restore Files

1. First mount the backup:

```bash
mkdir ~/restore-point
borg mount /var/borg/local_queue::archive-name ~/restore-point
```

2. Copy needed files from ~/restore-point
3. Unmount when done:

```bash
borg umount ~/restore-point
```

## Maintenance

### Prune Old Backups

Edit `/usr/local/bin/borg_backup.sh` to modify retention:

```bash
# Current settings keep:
# - 4 latest daily
# - 2 weekly
# - 2 monthly
borg prune --stats "$REPOSITORY" --keep-daily=4 --keep-weekly=2 --keep-monthly=2
```

### Check Repository Integrity

_On backup server:_

```bash
borg check ~/borg-repositories/client-pc
```

## Troubleshooting

### Common Issues

1. **Permission Denied**:

   - Verify SSH key permissions: `chmod 600 ~/.ssh/id_borg`
   - Check remote directory ownership

2. **No Space Left**:

   - Check local queue: `df -h /var/borg`
   - Check remote storage: `borg info remote:repo`

3. **Sync Failing**:
   - Test connection: `ssh -i ~/.ssh/id_borg backup-user@server borg list repo`
   - Check network: `ping backup-server.example.com`

## Security Notes

1. The backup server should only allow SSH key authentication
2. Repository passphrase should be strong and stored securely
3. Regular integrity checks are recommended
4. Consider using a dedicated backup user with restricted permissions
