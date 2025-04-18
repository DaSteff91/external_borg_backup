#!/bin/bash

# --- Auto-Confirm Borg Settings For Automation ---
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# --- Configuration ---
LOCAL_QUEUE="/var/borg/local_queue"
REMOTE_REPO="user@example.com:/path/to/remote/repo"
CREDENTIALS_FILE="/etc/borg/crypted_password.cred"
LOG_DIR="/var/log/borg"
LOG_FILE="$LOG_DIR/backup.log"
SSH_KEY="/home/user/.ssh/id_ed25519"
PING_TARGET="example.com"

# --- Initialize Logging ---
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "=== Starting Local Backup Queue Sync ==="

# --- Validate Configuration ---
validate_config() {
    local errors=0
    
    if [ ! -d "$LOCAL_QUEUE" ]; then
        log "ERROR: Local queue directory $LOCAL_QUEUE does not exist"
        errors=$((errors+1))
    fi
    
    if [ -z "$REMOTE_REPO" ]; then
        log "ERROR: Remote repository not configured"
        errors=$((errors+1))
    fi
    
    if [ ! -f "$SSH_KEY" ]; then
        log "ERROR: SSH key not found at $SSH_KEY"
        errors=$((errors+1))
    fi
    
    if [ -z "$PING_TARGET" ]; then
        log "ERROR: Ping target not configured"
        errors=$((errors+1))
    fi
    
    return $errors
}

validate_config || {
    log "FATAL: Configuration validation failed"
    exit 1
}

# --- Ensure SSH agent is running ---
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval $(ssh-agent)
    ssh-add "$SSH_KEY" || {
        log "ERROR: Failed to add SSH key"
        exit 1
    }
fi

# --- Load Passphrase ---
if [ -f "$CREDENTIALS_FILE" ]; then
    export BORG_PASSPHRASE=$(systemd-creds decrypt "$CREDENTIALS_FILE" 2>/dev/null || {
        log "ERROR: Failed to decrypt credentials"
        exit 1
    })
else
    log "ERROR: Credentials file missing at $CREDENTIALS_FILE"
    exit 1
fi

# --- Check Connectivity ---
if ! ping -c 1 "$PING_TARGET" &> /dev/null; then
    log "ERROR: No network connectivity - aborting sync"
    exit 1
fi

# --- Sync Loop ---
sync_failed=false

for backup in $(borg list "$LOCAL_QUEUE" --short); do
    log "Syncing $backup..."

    # Create temporary mountpoint
    MOUNTPOINT="/tmp/borg-mount-$backup"
    mkdir -p "$MOUNTPOINT"

    # Ensure cleanup happens on script exit
    trap 'borg umount "$MOUNTPOINT" 2>/dev/null; rmdir "$MOUNTPOINT"' EXIT

    # Mount local archive
    if borg mount "$LOCAL_QUEUE"::"$backup" "$MOUNTPOINT"; then

        # Create archive remotely using mounted contents
        if borg create --stats "$REMOTE_REPO"::"$backup" "$MOUNTPOINT"; then

            # Check if archive exists remotely before deleting local one
            if borg list "$REMOTE_REPO" --short | grep -q "^$backup$"; then
                borg delete "$LOCAL_QUEUE"::"$backup"
                log "Success: Synced and removed $backup"
            else
                log "ERROR: Remote archive $backup not found after sync — skipping delete"
                sync_failed=true
            fi

        else
            log "ERROR: Failed to create remote archive for $backup"
            sync_failed=true
        fi

        borg umount "$MOUNTPOINT"
    else
        log "ERROR: Failed to mount $backup"
        sync_failed=true
    fi

    rm -rf "$MOUNTPOINT"
done

if $sync_failed; then
    log "=== Backup Sync Failed for one or more archives ==="
    exit 1
else
    log "=== Backup Sync Completed Successfully ==="
fi

# --- Prune Local Backups ---
log "Pruning local queue..."
borg prune --keep-last=3 --stats "$LOCAL_QUEUE" || {
    log "WARNING: Local prune failed (non-critical)"
}

# --- Cleanup ---
find /tmp -maxdepth 1 -type d -name 'borg-mount-*' -exec fusermount3 -u {} \; -exec rmdir {} \; 2>/dev/null
unset BORG_PASSPHRASE
log "=== Backup Sync Completed ==="
exit 0