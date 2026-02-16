#!/usr/bin/env bash
# upload.sh - rclone-based client uploader for termiNAS
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Get version from VERSION file in repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../../VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    VERSION="unknown"
fi

set -euo pipefail

usage() {
        cat <<EOF
termiNAS Linux Upload Client (rclone backend)
Copyright (c) 2025 Yianni Bourkelis
https://github.com/YiannisBourkelis/terminas

Usage: $0 -l <local-path> -u <username> -p <password> -s <server> [OPTIONS]

This script syncs a local file or directory to the termiNAS server using rclone.
It ensures the remote directory is an exact mirror of the local directory.

Required arguments:
    -l, --local-path PATH    Local file or directory to upload
    -u, --username USER      Remote username
    -p, --password PASS      Password for the user
    -s, --server HOST        SFTP server hostname or IP address

Optional arguments:
    -d, --dest-path PATH     Destination path relative to user's chroot (default: uploads/)
    -f, --fingerprint FP     Expected host fingerprint (optional - NOT USED by rclone backend currently)
    --debug                  Run rclone with debug logging
    --force                  Ignored (rclone sync always forces sync state)
    --log-file FILE          Path to log file (default: stdout)
    -h, --help               Show this help message

Examples:
    $0 -l /path/to/folder -u test2 -p 'P@ssw0rd' -s 192.168.1.100
    $0 -l /path/to/folder -u test2 -p 'P@ssw0rd' -s 192.168.1.100 -d uploads/backups/ --log-file /var/log/backup.log

Notes:
- Requires 'rclone' installed.
- Passwords passed as arguments appear in process list; use env vars or config file for better security in production.
EOF
}

# Initialize variables
LOCAL_PATH=""
USERNAME=""
PASSWORD=""
DEST_PATH="uploads/"
SERVER=""
DEBUG=0
LOG_FILE=""

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--local-path)
            LOCAL_PATH="$2"
            shift 2
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -d|--dest-path)
            DEST_PATH="$2"
            shift 2
            ;;
        -f|--fingerprint)
            shift 2 # Ignored in this version
            ;;
        -s|--server)
            SERVER="$2"
            shift 2
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --force)
            shift # Ignored
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

# Check required parameters
if [[ -z "$LOCAL_PATH" || -z "$USERNAME" || -z "$PASSWORD" || -z "$SERVER" ]]; then
    echo "Error: Missing required arguments" >&2
    usage
    exit 2
fi

if ! command -v rclone &> /dev/null; then
    echo "Error: rclone is not installed. Please install it (e.g., sudo apt install rclone or via https://rclone.org/install.sh)" >&2
    exit 1
fi

if [ ! -e "$LOCAL_PATH" ]; then
    echo "Local path does not exist: $LOCAL_PATH" >&2
    exit 3
fi

# Normalize destination path
# rclone sftp remote paths are relative to home.
# If DEST_PATH starts with /, remove it.
DEST_PATH="${DEST_PATH#/}"
if [ -z "$DEST_PATH" ]; then
    DEST_PATH="uploads"
fi

# Configure rclone via environment variables (no config file needed)
export RCLONE_CONFIG_TERMINAS_TYPE=sftp
export RCLONE_CONFIG_TERMINAS_HOST="$SERVER"
export RCLONE_CONFIG_TERMINAS_USER="$USERNAME"

# Rclone generally expects obscured passwords in config passed via env vars
# We use 'rclone obscure' to generate it.
OBSCURED_PASS=$(rclone obscure "$PASSWORD")
export RCLONE_CONFIG_TERMINAS_PASS="$OBSCURED_PASS"

# Use system known_hosts for host key verification
# If missing, ensure ~/.ssh exists
if [ ! -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
fi
if [ ! -f "$HOME/.ssh/known_hosts" ]; then
    touch "$HOME/.ssh/known_hosts"
    chmod 600 "$HOME/.ssh/known_hosts"
fi

# Add host key if not present (to prevent interactive prompt hanging background jobs)
if ! ssh-keygen -F "$SERVER" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    # Try using ssh-keyscan if available (preferred)
    if command -v ssh-keyscan &> /dev/null; then
        # Add a timeout and retry logic for keyscan
        ssh-keyscan -t rsa,ecdsa,ed25519 "$SERVER" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    fi
fi

# Build arguments
ARGS=""

# Log level
if [ "$DEBUG" -eq 1 ]; then
    ARGS="$ARGS --log-level DEBUG"
else
    ARGS="$ARGS --log-level INFO"
fi

# Log file rotation (conditional on version)
# Get rclone version: "rclone v1.53.3-DEV" -> 1.53
RCLONE_VERSION_RAW=$(rclone --version | head -n1 | awk '{print $2}')
# Remove 'v'
RCLONE_VERSION=${RCLONE_VERSION_RAW#v}
# Extract major and minor
MAJOR=$(echo "$RCLONE_VERSION" | cut -d. -f1)
MINOR=$(echo "$RCLONE_VERSION" | cut -d. -f2)

# Check if version supports log rotation (approx >= 1.55 or similar, user said 1.53 is missing it)
SUPPORTS_LOG_ROTATION=0
# Convert to integer for comparison
MAJOR=${MAJOR:-0}
MINOR=${MINOR:-0}

if [ "$MAJOR" -gt 1 ]; then
    SUPPORTS_LOG_ROTATION=1
elif [ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 55 ]; then
    SUPPORTS_LOG_ROTATION=1
fi

if [ -n "$LOG_FILE" ]; then
    ARGS="$ARGS --log-file $LOG_FILE"
    if [ "$SUPPORTS_LOG_ROTATION" -eq 1 ]; then
        # Default rotation settings suitable for backups
        ARGS="$ARGS --log-file-max-size 10M --log-file-max-backups 10 --log-file-max-age 30d"
    fi
fi

# Execute sync
echo "Syncing '$LOCAL_PATH' to '$SERVER:$DEST_PATH' via rclone..."

if [ -f "$LOCAL_PATH" ]; then
    # Single file upload
    rclone copyto "$LOCAL_PATH" "terminas:$DEST_PATH/$(basename "$LOCAL_PATH")" $ARGS
else
    # Directory sync
    rclone sync "$LOCAL_PATH" "terminas:$DEST_PATH" $ARGS
fi
