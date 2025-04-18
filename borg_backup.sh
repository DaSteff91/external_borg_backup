#!/bin/bash

# --- Auto-Confirm Borg Settings For Automation ---
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# --- Configuration ---
# IMPORTANT: Users must configure these variables before use
REPOSITORY=""  # e.g., "user@example.com:/path/to/repo"
SSH_KEY=""     # e.g., "/home/user/.ssh/id_ed25519"
BACKUP_PATHS="" # e.g., "/etc /var /home/user/important_files"
CREDENTIALS_FILE="/etc/borg/crypted_password.cred"
LOCAL_FALLBACK_DIR="/var/borg/local_queue"
LOG_DIR="/var/log/borg"
LOG_FILE="$LOG_DIR/backup.log"
MAX_LOG_SIZE=10485760
SERVER_PING_TARGET="" # e.g., "example.com"

# --- Validate Configuration ---
validate_config() {
    local errors=0
    
    if [ -z "$REPOSITORY" ]; then
        log "ERROR: REPOSITORY is not set in configuration"
        errors=$((errors+1))
    fi
    
    if [ -z "$SSH_KEY" ]; then
        log "ERROR: SSH_KEY is not set in configuration"
        errors=$((errors+1))
    fi
    
    if [ -z "$BACKUP_PATHS" ]; then
        log "ERROR: BACKUP_PATHS is not set in configuration"
        errors=$((errors+1))
    fi
    
    if [ -z "$SERVER_PING_TARGET" ]; then
        log "ERROR: SERVER_PING_TARGET is not set in configuration"
        errors=$((errors+1))
    fi
    
    return $errors
}

# --- Initialize Logging ---
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# --- Trim log entries older than 7 days ---
TRIM_DAYS=7

if [ -f "$LOG_FILE" ]; then
    TMP_FILE=$(mktemp)

    while IFS= read -r line; do
        ts=$(echo "$line" | grep -oP '^\[\K[0-9-]+ [0-9:]+' || true)

        if [ -n "$ts" ]; then
            ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            cutoff_epoch=$(date -d "$TRIM_DAYS days ago" +%s)

            if [ "$ts_epoch" -gt "$cutoff_epoch" ]; then
                echo "$line" >> "$TMP_FILE"
            fi
        else
            echo "$line" >> "$TMP_FILE"
        fi
    done < "$LOG_FILE"

    mv "$TMP_FILE" "$LOG_FILE"
fi

log "=== Starting Borg Backup Process ==="

# Validate configuration before proceeding
validate_config || {
    log "FATAL: Invalid configuration - please fix the errors above"
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

# --- Load Passphrase Securely ---
if [ -f "$CREDENTIALS_FILE" ]; then
    export BORG_PASSPHRASE=$(systemd-creds decrypt "$CREDENTIALS_FILE" 2>/dev/null || {
        log "ERROR: Failed to decrypt credentials file"
        exit 1
    })
else
    log "ERROR: Credentials file missing at $CREDENTIALS_FILE"
    exit 1
fi

# --- Creates offline repo in case of no internet connection ---
for i in {1..6}; do
    if ping -c 1 "$SERVER_PING_TARGET" &> /dev/null; then
        break
    fi

    if [ $i -eq 6 ]; then
        log "WARNING: Offline - Storing backup locally"

        # Initialize local fallback repo if it doesn't exist
        if [ ! -d "$LOCAL_FALLBACK_DIR/config" ]; then
            log "Creating local fallback repo..."
            borg init --encryption=repokey "$LOCAL_FALLBACK_DIR" || {
                log "ERROR: Failed to initialize local fallback repo"
                exit 1
            }
        fi

        # Perform local backup
        if borg create --stats --compression lz4 \
            "$LOCAL_FALLBACK_DIR::$(date +%Y-%m-%d_%H:%M:%S)" \
            $BACKUP_PATHS; then
            log "Local backup succeeded"
            exit 0
        else
            log "ERROR: Local backup failed"
            exit 1
        fi
    fi

    sleep 5
done

# --- Remote Backup ---
log "Starting remote backup..."
if borg create --stats --compression lz4 \
    "$REPOSITORY::$(date +%Y-%m-%d_%H:%M:%S)" \
    $BACKUP_PATHS; then
    log "Remote backup succeeded"
else
    log "ERROR: Remote backup failed"
    exit 1
fi

# --- Prune Old Backups ---
log "Pruning old backups..."
borg prune --stats "$REPOSITORY" --keep-daily=4 --keep-weekly=2 --keep-monthly=2 2>&1 | tee -a "$LOG_FILE" || {
    log "WARNING: Pruning failed (but not fatal)"
}

# --- Cleanup ---
unset BORG_PASSPHRASE
log "=== Backup process completed ==="
exit 0