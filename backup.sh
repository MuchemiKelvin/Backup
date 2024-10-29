#!/bin/bash

set -euo pipefail  # Exit on error, undefined var, and pipe failures

# Function for cleanup
cleanup() {
    echo "Cleaning up..."
    [ -d "$LOCAL_BACKUP_DIR/$DATE" ] && rm -rf "$LOCAL_BACKUP_DIR/$DATE"
    echo "Cleanup completed."
}

# Trap to catch errors and call cleanup
trap 'cleanup' ERR

# Configuration
CONFIG_FILE="/mnt/c/Users/ADMIN/Documents/Backup/.backup_config.sh"
source "$CONFIG_FILE" || { echo "Config file not found. Please create $CONFIG_FILE"; exit 1; }

# Variables (now set in config file)
# LOCAL_BACKUP_DIR="/mnt/c/Users/ADMIN/Documents/Backups"
# HOST=""
# REMOTE_USER=""
# REMOTE_BACKUP_DIR="/var/backup/backups"
# EXTERNAL_DRIVE="/mnt/e/Zandaux/Backups"
# REMOTE_SCRIPT_DIR="/var/backup/script"

DATE=$(date +%Y-%m-%d)
BACKUP_LOG="$LOCAL_BACKUP_DIR/backup_log_$DATE.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$BACKUP_LOG"
}

# Create local backup directory
mkdir -p "$LOCAL_BACKUP_DIR/$DATE"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Prompt for sudo password
read -s -p "Enter sudo password for remote server: " REMOTE_SUDO_PASSWORD
echo

# Execute remote backup scripts and capture the output
log "Starting remote backup process"
BACKUP_FILES=$(ssh $SSH_OPTS $REMOTE_USER@$HOST << EOF
    cd "$REMOTE_SCRIPT_DIR"
    # echo "$REMOTE_SUDO_PASSWORD" | sudo -S ./local_transfer_backup_script.sh
    # echo "$REMOTE_SUDO_PASSWORD" | sudo -S ./mysql_backup_script.sh
    latest_sql=\$(ls -t "$REMOTE_BACKUP_DIR"/*.sql 2>/dev/null | head -n 1)
    latest_tar=\$(ls -t "$REMOTE_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -n 1)
    if [ -n "\$latest_sql" ] && [ -n "\$latest_tar" ]; then
        find "\$latest_sql" "\$latest_tar" -printf "%s %p\n" | sort -n | awk '{print \$2}'
    elif [ -n "\$latest_sql" ]; then
        echo "\$latest_sql"
    elif [ -n "\$latest_tar" ]; then
        echo "\$latest_tar"
    fi
EOF
)

# Clear the password variable
REMOTE_SUDO_PASSWORD=""

# Filter out any lines that don't end with .sql or .tar.gz
BACKUP_FILES=$(echo "$BACKUP_FILES" | grep -E '\.sql$|\.tar\.gz$')

# Download the most recent .sql and .tar.gz backup files, starting with the smallest
if [ -n "$BACKUP_FILES" ]; then
    log "Transferring most recent backup files, starting with the smallest"
    echo "$BACKUP_FILES" | while IFS= read -r file; do
        log "Attempting to transfer: $file"
        if rsync -avz --protect-args -e "ssh $SSH_OPTS" "$REMOTE_USER@$HOST:$file" "$LOCAL_BACKUP_DIR/$DATE/"; then
            log "File transferred successfully: $file"
        else
            log "Failed to transfer file: $file. Error code: $?"
            exit 1
        fi
    done
else
    log "No recent backup files found to transfer"
    exit 1
fi

# Transfer to external drive
if [ -d "$EXTERNAL_DRIVE" ]; then
    log "Transferring to external drive at $EXTERNAL_DRIVE"
    if rsync -avz "$LOCAL_BACKUP_DIR/$DATE/" "$EXTERNAL_DRIVE/$DATE/"; then
        log "Backup transferred to external drive successfully"
    else
        log "Failed to transfer backup to external drive. Error code: $?"
        exit 1
    fi
else
    log "External drive not found at $EXTERNAL_DRIVE"
    lsblk >> "$BACKUP_LOG"
    exit 1
fi

# Clean up old backups (keep last 7 days)
find "$LOCAL_BACKUP_DIR" -type d -mtime +7 -exec rm -rf {} +

log "Backup completed successfully"

# Remove the trap as we're done
trap - ERR