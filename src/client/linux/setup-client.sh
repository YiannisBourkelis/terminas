#!/bin/bash

# setup-client.sh - Interactive setup for automated daily backups
# This script configures a Linux client to automatically backup files to a termiNAS server
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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/upload.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if upload.sh exists
if [ ! -f "$UPLOAD_SCRIPT" ]; then
    print_error "upload.sh not found at: $UPLOAD_SCRIPT"
    exit 1
fi

print_header "termiNAS Client Setup"
echo "This script will help you configure automated daily backups."
echo "Copyright (c) 2025 Yianni Bourkelis"
echo "https://github.com/YiannisBourkelis/terminas"
echo ""

# Gather information from user
print_info "Please provide the following information:"
echo ""

# Local path to backup
while true; do
    read -p "Local path to backup (e.g., /var/backup/web1): " LOCAL_PATH
    LOCAL_PATH="${LOCAL_PATH%/}"  # Remove trailing slash
    if [ -z "$LOCAL_PATH" ]; then
        print_error "Local path cannot be empty"
        continue
    fi
    if [ ! -e "$LOCAL_PATH" ]; then
        print_warning "Path does not exist: $LOCAL_PATH"
        read -p "Do you want to create it? (y/n): " CREATE_PATH
        if [[ "$CREATE_PATH" =~ ^[Yy]$ ]]; then
            mkdir -p "$LOCAL_PATH"
            print_success "Created directory: $LOCAL_PATH"
            break
        else
            continue
        fi
    fi
    break
done

# Backup server
while true; do
    read -p "Backup server hostname or IP (e.g., backup.example.com): " BACKUP_SERVER
    if [ -z "$BACKUP_SERVER" ]; then
        print_error "Server hostname/IP cannot be empty"
        continue
    fi
    break
done

# Backup username
while true; do
    read -p "Backup username: " BACKUP_USERNAME
    if [ -z "$BACKUP_USERNAME" ]; then
        print_error "Username cannot be empty"
        continue
    fi
    break
done

# Backup password
while true; do
    read -s -p "Backup password: " BACKUP_PASSWORD
    echo ""
    if [ -z "$BACKUP_PASSWORD" ]; then
        print_error "Password cannot be empty"
        continue
    fi
    read -s -p "Confirm password: " BACKUP_PASSWORD_CONFIRM
    echo ""
    if [ "$BACKUP_PASSWORD" != "$BACKUP_PASSWORD_CONFIRM" ]; then
        print_error "Passwords do not match"
        continue
    fi
    break
done

# Remote destination path
read -p "Remote destination path (default: /uploads): " DEST_PATH
DEST_PATH="${DEST_PATH:-/uploads}"

# Backup time
while true; do
    read -p "Backup time (HH:MM in 24-hour format, e.g., 01:00): " BACKUP_TIME
    BACKUP_TIME="${BACKUP_TIME:-01:00}"
    if [[ ! "$BACKUP_TIME" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        print_error "Invalid time format. Use HH:MM (e.g., 01:00)"
        continue
    fi
    break
done

# Extract hour and minute
BACKUP_HOUR=$(echo "$BACKUP_TIME" | cut -d: -f1)
BACKUP_MINUTE=$(echo "$BACKUP_TIME" | cut -d: -f2)

# Backup name (used for scripts and logs)
BACKUP_NAME=$(basename "$LOCAL_PATH")
read -p "Backup job name (default: $BACKUP_NAME): " CUSTOM_NAME
BACKUP_NAME="${CUSTOM_NAME:-$BACKUP_NAME}"

# Remove spaces and special characters from backup name
BACKUP_NAME=$(echo "$BACKUP_NAME" | tr -cd '[:alnum:]_-')

echo ""
print_header "Configuration Summary"
echo "Local path:      $LOCAL_PATH"
echo "Backup server:   $BACKUP_SERVER"
echo "Username:        $BACKUP_USERNAME"
echo "Remote path:     $DEST_PATH"
echo "Backup time:     $BACKUP_TIME daily"
echo "Job name:        $BACKUP_NAME"
echo ""
read -p "Is this correct? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_error "Setup cancelled"
    exit 0
fi

echo ""
print_header "Installing Backup Configuration"

# Create backup scripts directory
SCRIPTS_DIR="/usr/local/bin/terminas-backup"
mkdir -p "$SCRIPTS_DIR"
print_success "Created scripts directory: $SCRIPTS_DIR"

# Create credentials directory
CREDS_DIR="/root/.terminas-credentials"
CREDS_FILE="$CREDS_DIR/${BACKUP_NAME}.conf"
mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

# Write credentials file
cat > "$CREDS_FILE" <<EOF
# termiNAS backup credentials for: $BACKUP_NAME
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
# Copyright (c) 2025 Yianni Bourkelis

BACKUP_USERNAME="$BACKUP_USERNAME"
BACKUP_PASSWORD="$BACKUP_PASSWORD"
BACKUP_SERVER="$BACKUP_SERVER"
EOF
chmod 600 "$CREDS_FILE"
print_success "Created secure credentials file: $CREDS_FILE"

# Create backup script
BACKUP_SCRIPT="$SCRIPTS_DIR/backup-${BACKUP_NAME}.sh"
cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
# Automated backup script for: $BACKUP_NAME
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

LOG_FILE="/var/log/terminas-${BACKUP_NAME}.log"
UPLOAD_SCRIPT="$UPLOAD_SCRIPT"
CREDS_FILE="$CREDS_FILE"
LOCAL_PATH="$LOCAL_PATH"
DEST_PATH="$DEST_PATH"

# Ensure log directory exists
mkdir -p "\$(dirname "\$LOG_FILE")"

# Load credentials
if [ ! -f "\$CREDS_FILE" ]; then
    echo "ERROR: Credentials file not found: \$CREDS_FILE" >> "\$LOG_FILE"
    exit 1
fi
source "\$CREDS_FILE"

# Check if local path exists
if [ ! -e "\$LOCAL_PATH" ]; then
    echo "ERROR: Local path not found: \$LOCAL_PATH" >> "\$LOG_FILE"
    exit 1
fi

# Log start time
echo "==========================================" >> "\$LOG_FILE"
echo "Backup started at \$(date '+%Y-%m-%d %H:%M:%S')" >> "\$LOG_FILE"
echo "Local path: \$LOCAL_PATH" >> "\$LOG_FILE"

# Run the upload
"\$UPLOAD_SCRIPT" \\
    --local-path "\$LOCAL_PATH" \\
    --username "\$BACKUP_USERNAME" \\
    --password "\$BACKUP_PASSWORD" \\
    --dest-path "\$DEST_PATH" \\
    --server "\$BACKUP_SERVER" \\
    --log-file "\$LOG_FILE"

EXIT_CODE=\$?

# Log completion
if [ \$EXIT_CODE -eq 0 ]; then
    echo "Backup completed successfully at \$(date '+%Y-%m-%d %H:%M:%S')" >> "\$LOG_FILE"
else
    echo "Backup FAILED with exit code \$EXIT_CODE at \$(date '+%Y-%m-%d %H:%M:%S')" >> "\$LOG_FILE"
fi
echo "" >> "\$LOG_FILE"

exit \$EXIT_CODE
EOF
chmod +x "$BACKUP_SCRIPT"
print_success "Created backup script: $BACKUP_SCRIPT"

# Create logrotate configuration
LOGROTATE_FILE="/etc/logrotate.d/terminas-${BACKUP_NAME}"
cat > "$LOGROTATE_FILE" <<EOF
/var/log/terminas-${BACKUP_NAME}.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
print_success "Created log rotation config: $LOGROTATE_FILE"

# Add cron job
CRON_JOB="$BACKUP_MINUTE $BACKUP_HOUR * * * $BACKUP_SCRIPT"
CRON_COMMENT="# termiNAS automated backup: $BACKUP_NAME"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
    print_warning "Cron job already exists for this backup"
else
    (crontab -l 2>/dev/null; echo ""; echo "$CRON_COMMENT"; echo "$CRON_JOB") | crontab -
    print_success "Added cron job to run daily at $BACKUP_TIME"
fi

# Check if rclone is installed
if ! command -v rclone &> /dev/null; then
    print_warning "rclone is not installed (required for backups)"
    read -p "Would you like to install rclone now? (y/n): " INSTALL_RCLONE
    if [[ "$INSTALL_RCLONE" =~ ^[Yy]$ ]]; then
        print_info "Attempting to install rclone..."
        if command -v curl &> /dev/null; then
            curl https://rclone.org/install.sh | bash
            if [ $? -eq 0 ]; then
                print_success "Installed rclone"
            else
                print_error "Failed to install rclone via script"
            fi
        elif command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y rclone
            print_success "Installed rclone via apt"
        elif command -v yum &> /dev/null; then
            yum install -y rclone
            print_success "Installed rclone via yum"
        else
            print_error "Cloud not install rclone automatically. Please install it manually from https://rclone.org/install/"
            exit 1
        fi
    else
        print_error "rclone is required. Please install it manually and run this script again."
        exit 1
    fi
else
    print_success "rclone is installed"
fi

echo ""
print_header "Setup Complete!"
echo ""
print_success "Backup job '$BACKUP_NAME' has been configured successfully!"
echo ""
print_info "Configuration details:"
echo "  • Backup script:    $BACKUP_SCRIPT"
echo "  • Credentials:      $CREDS_FILE"
echo "  • Log file:         /var/log/terminas-${BACKUP_NAME}.log"
echo "  • Schedule:         Daily at $BACKUP_TIME"
echo ""
print_info "Useful commands:"
echo "  • Test backup now:      $BACKUP_SCRIPT"
echo "  • View logs:            tail -f /var/log/terminas-${BACKUP_NAME}.log"
echo "  • List cron jobs:       crontab -l"
echo "  • Edit cron schedule:   crontab -e"
echo ""
read -p "Would you like to test the backup now? (y/n): " TEST_NOW
if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    echo ""
    print_info "Running test backup..."
    echo ""
    "$BACKUP_SCRIPT"
    echo ""
    if [ $? -eq 0 ]; then
        print_success "Test backup completed successfully!"
        echo ""
        print_info "You can view the full log at: /var/log/terminas-${BACKUP_NAME}.log"
    else
        print_error "Test backup failed. Check the log for details:"
        echo "  tail -100 /var/log/terminas-${BACKUP_NAME}.log"
    fi
else
    print_info "You can test the backup manually later by running:"
    echo "  $BACKUP_SCRIPT"
fi

echo ""
print_success "All done! Your backups will run automatically at $BACKUP_TIME daily."
echo ""
