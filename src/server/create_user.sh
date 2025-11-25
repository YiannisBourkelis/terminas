#!/bin/bash

# create_user.sh - Create a backup user with secure password and versioning setup
# Usage: ./create_user.sh <username> [-p|--password <password>] [-s|--samba]
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

# Source common functions
COMMON_LIB="$SCRIPT_DIR/common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    echo "ERROR: Cannot find common.sh library"
    exit 1
fi

# Function to setup Samba share with strict security
setup_samba_share() {
    local username="$1"
    local password="$2"
    local enable_timemachine="${3:-false}"
    
    echo "Setting up Samba share for $username..."
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        echo "To enable Samba support, run setup.sh with the --samba option:"
        echo "  ./setup.sh --samba"
        echo "Then re-run this command to create the user with Samba support."
        return 1
    fi
    
    # Enable Samba user with the same password
    echo -e "$password\n$password" | smbpasswd -a "$username" -s
    
    # Create Samba configuration for this user with strict security
    local smb_conf="/etc/samba/smb.conf.d/$username.conf"
    mkdir -p /etc/samba/smb.conf.d
    
    # Create per-user config file for easy maintenance
    cat > "$smb_conf" << EOF
[$username-backup]
   path = /home/$username/uploads
   browseable = no
   writable = yes
   guest ok = no
   valid users = $username
   create mask = 0644
   directory mask = 0755
   force user = $username
   force group = backupusers
   # Strict security settings
   read only = no
   public = no
   printable = no
   store dos attributes = no
   map archive = no
   map hidden = no
   map system = no
   map readonly = no
   # VFS audit module for tracking SMB file operations
   vfs objects = full_audit
   full_audit:prefix = %u|%I|%m
   full_audit:success = connect disconnect open close write pwrite
   full_audit:failure = connect
   full_audit:facility = local1
   full_audit:priority = notice
EOF

    # Add Time Machine share if requested
    if [ "$enable_timemachine" = "true" ]; then
        cat >> "$smb_conf" << EOF

[$username-timemachine]
   comment = Time Machine Backup for $username
   path = /home/$username/uploads
   browseable = yes
   writable = yes
   read only = no
   create mask = 0700
   directory mask = 0700
   valid users = $username
   vfs objects = fruit streams_xattr full_audit
   fruit:aapl = yes
   fruit:time machine = yes
   fruit:time machine max size = 0
   # VFS audit module for tracking Time Machine connections
   full_audit:prefix = %u|%I|%m|timemachine
   full_audit:success = connect disconnect open close write pwrite
   full_audit:failure = connect
   full_audit:facility = local1
   full_audit:priority = notice
EOF
    fi
    
    # Add explicit include to main smb.conf for this user's config
    # (Per-user config files are loaded via explicit includes, not wildcards)
    if [ -f /etc/samba/smb.conf ] && ! grep -q "^include = $smb_conf" /etc/samba/smb.conf 2>/dev/null; then
        # Find the line with "# Explicit includes for per-user configurations" and add after it
        if grep -q "# Explicit includes for per-user configurations" /etc/samba/smb.conf; then
            # Add after the comment line
            sed -i "/# Explicit includes for per-user configurations/a include = $smb_conf" /etc/samba/smb.conf
        else
            # Fallback: append at end
            echo "include = $smb_conf" >> /etc/samba/smb.conf
        fi
    fi
    
    # Restart Samba services (nmbd may not be running on all systems)
    if systemctl restart smbd nmbd 2>/dev/null; then
        : # Both services restarted successfully
    else
        systemctl restart smbd 2>/dev/null || true
    fi
    
    echo "  ✓ Samba share created: //$HOSTNAME/$username-backup"
    if [ "$enable_timemachine" = "true" ]; then
        echo "  ✓ Time Machine share created: //$HOSTNAME/$username-timemachine"
    fi
    echo "  ✓ Access credentials: $username / [same password as SFTP]"
}

# Parse command line arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [-p|--password <password>] [-s|--samba] [-t|--timemachine] [-q|--quota <GB>]"
    echo ""
    echo "Options:"
    echo "  -p, --password     Manually specify password (must be 30+ chars with lowercase, uppercase, and numbers)"
    echo "  -s, --samba        Enable Samba (SMB) sharing for uploads directory"
    echo "  -t, --timemachine  Enable macOS Time Machine support (requires --samba)"
    echo "  -q, --quota        Set storage quota in GB (0 = unlimited, default from /etc/terminas-retention.conf)"
    echo ""
    echo "If no password is provided, a secure 64-character random password will be generated."
    echo "Samba sharing allows other applications to use the uploads directory as a network share."
    echo "Time Machine support enables macOS backup functionality via Samba."
    echo "Quota limits total disk usage (uploads + all snapshots) tracked via Btrfs qgroups."
    exit 1
fi

USERNAME=$1
PASSWORD=""
ENABLE_SAMBA=false
ENABLE_TIMEMACHINE=false
QUOTA_GB=""

# Parse optional parameters
shift
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--password)
            if [ -z "${2:-}" ]; then
                echo "ERROR: --password requires a value"
                exit 1
            fi
            PASSWORD="$2"
            shift 2
            ;;
        -s|--samba)
            ENABLE_SAMBA=true
            shift
            ;;
        -t|--timemachine)
            ENABLE_TIMEMACHINE=true
            shift
            ;;
        -q|--quota)
            if [ -z "${2:-}" ]; then
                echo "ERROR: --quota requires a value (quota in GB)"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --quota must be a positive integer (GB)"
                exit 1
            fi
            QUOTA_GB="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown parameter: $1"
            echo "Usage: $0 <username> [-p|--password <password>] [-s|--samba] [-t|--timemachine] [-q|--quota <GB>]"
            exit 1
            ;;
    esac
done

# Validate Time Machine dependency
if [ "$ENABLE_TIMEMACHINE" = true ] && [ "$ENABLE_SAMBA" = false ]; then
    echo "ERROR: --timemachine requires --samba to be enabled"
    echo "Usage: $0 <username> --samba --timemachine"
    exit 1
fi

# Check if user exists
if id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME already exists."
    exit 1
fi

# Generate or validate password
if [ -z "$PASSWORD" ]; then
    # Generate secure password
    PASSWORD=$(pwgen -s 64 1)
    echo "Generated secure password: $PASSWORD"
else
    # Validate manually provided password
    if ! validate_password "$PASSWORD"; then
        exit 1
    fi
    echo "Using provided password (validated: 30+ chars, lowercase, uppercase, numbers)"
fi

echo "Creating user $USERNAME with password: $PASSWORD"
# Create user
useradd -m -g backupusers -s /usr/sbin/nologin "$USERNAME"

# Set the user's password securely using chpasswd.
# chpasswd uses the system's default password hashing algorithm (yescrypt on modern systems).
# This is more reliable than manually creating hashes, as it respects PAM configuration.
# Note: chpasswd will fail if the password contains a colon ':' character.
echo "$USERNAME:$PASSWORD" | chpasswd

# Set ownership for chroot (home must be root-owned)
chown root:root "/home/$USERNAME"
chmod 755 "/home/$USERNAME"

# Create Btrfs subvolume for uploads (instead of regular directory)
echo "Creating Btrfs subvolume for uploads..."
if btrfs subvolume create "/home/$USERNAME/uploads" >/dev/null; then
    echo "  ✓ Created uploads subvolume"
else
    echo "  ERROR: Failed to create Btrfs subvolume"
    echo "  Make sure /home is on a Btrfs filesystem"
    userdel -r "$USERNAME" 2>/dev/null
    exit 1
fi

# Create versions directory (regular directory, will contain snapshots)
mkdir -p "/home/$USERNAME/versions"

# Set permissions
# uploads subvolume should be writable only by the user
chown "$USERNAME:backupusers" "/home/$USERNAME/uploads"
chmod 700 "/home/$USERNAME/uploads"
# versions are root-owned and not writable by the user
chown root:backupusers "/home/$USERNAME/versions"
chmod 755 "/home/$USERNAME/versions"

# Setup Btrfs quota for user (if requested or configured)
if [ -z "$QUOTA_GB" ]; then
    # Load default quota from config file
    if [ -f /etc/terminas-retention.conf ]; then
        source /etc/terminas-retention.conf
        QUOTA_GB="${DEFAULT_QUOTA_GB:-0}"
    else
        QUOTA_GB=0
    fi
fi

if [ "$QUOTA_GB" -gt 0 ]; then
    echo "Setting up Btrfs quota: ${QUOTA_GB}GB..."
    
    # Check if quotas are enabled
    if ! btrfs qgroup show /home &>/dev/null; then
        echo "  ⚠ WARNING: Btrfs quotas not enabled on /home"
        echo "  Run setup.sh to enable quotas, or manually: btrfs quota enable /home"
        echo "  Skipping quota setup"
    else
        # Get the qgroup ID for the uploads subvolume (this is what actually holds data)
        UPLOADS_QGROUP=$(btrfs subvolume show "/home/$USERNAME/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
        
        if [ -n "$UPLOADS_QGROUP" ]; then
            # Create level 1 qgroup for tracking (1/<subvol_id>)
            # This will track the uploads subvolume + all snapshot subvolumes under versions/
            USER_QGROUP="1/$UPLOADS_QGROUP"
            
            # Create the qgroup
            if btrfs qgroup create "$USER_QGROUP" /home 2>/dev/null; then
                echo "  ✓ Created qgroup: $USER_QGROUP"
            fi
            
            # Assign the uploads subvolume's qgroup (0/<subvol_id>) to our tracking qgroup
            if btrfs qgroup assign "0/$UPLOADS_QGROUP" "$USER_QGROUP" /home 2>/dev/null; then
                echo "  ✓ Assigned uploads subvolume to qgroup"
            fi
            
            # Set quota limit (convert GB to bytes)
            # Use exclusive (-e) limit for physical disk usage (deduped/CoW-aware)
            # This counts actual disk blocks used, not logical file sizes
            # Snapshots sharing blocks with uploads via CoW are counted once, not twice
            QUOTA_BYTES=$((QUOTA_GB * 1024 * 1024 * 1024))
            if btrfs qgroup limit -e "$QUOTA_BYTES" "$USER_QGROUP" /home 2>/dev/null; then
                echo "  ✓ Set quota limit: ${QUOTA_GB}GB (physical/exclusive)"
            else
                echo "  ⚠ WARNING: Failed to set quota limit"
            fi
        else
            echo "  ⚠ WARNING: Could not determine subvolume ID for quota setup"
        fi
    fi
elif [ "$QUOTA_GB" -eq 0 ]; then
    echo "Quota: Unlimited (not enforced)"
fi

# Setup Samba share if requested
if [ "$ENABLE_SAMBA" = "true" ]; then
    if ! setup_samba_share "$USERNAME" "$PASSWORD" "$ENABLE_TIMEMACHINE"; then
        echo "Failed to setup Samba share for user $USERNAME."
        echo "Cleaning up..."
        userdel -r "$USERNAME" 2>/dev/null
        exit 1
    fi
    if [ "$ENABLE_TIMEMACHINE" = "true" ]; then
        echo "User $USERNAME created successfully with Samba and Time Machine support."
        echo ""
        echo "macOS Setup Instructions:"
        echo "1. Connect to the share in Finder first:"
        echo "   - Open Finder → Go → Connect to Server (or press Command+K)"
        echo "   - Enter: smb://<server-ip>/${USERNAME}-timemachine"
        echo "   - Click Connect and enter credentials:"
        echo "     Username: ${USERNAME}"
        echo "     Password: [the password shown above]"
        echo ""
        echo "2. Configure Time Machine:"
        echo "   - Open System Preferences → Time Machine"
        echo "   - Click '+' (Add Disk) or 'Select Disk'"
        echo "   - Select '${USERNAME}-timemachine' from the list"
        echo "   - Time Machine will now use this network share for backups"
    else
        echo "User $USERNAME created successfully with Samba support."
    fi
else
    echo "User $USERNAME created successfully."
fi

echo ""
echo "Configuration:"
echo "  Upload subvolume: /home/$USERNAME/uploads (Btrfs subvolume)"
echo "  Versions directory: /home/$USERNAME/versions (read-only Btrfs snapshots)"
if [ "$QUOTA_GB" -gt 0 ]; then
    echo "  Storage quota: ${QUOTA_GB}GB (uploads + all snapshots)"
else
    echo "  Storage quota: Unlimited"
fi
echo ""
echo "Btrfs snapshots will be created automatically on file uploads via inotify monitoring."