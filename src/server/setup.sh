#!/bin/bash

# setup.sh - Setup script for Debian backup server with Btrfs snapshots
# This script configures a Debian system to allow remote clients to upload files via SCP/SFTP
# with automatic Btrfs snapshot versioning for ransomware protection.
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas
#
# Requirements:
#   - Debian 12 or later
#   - Btrfs filesystem for /home

# Get version from VERSION file in repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../../VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    VERSION="unknown"
fi

set -e

# Parse command line arguments
ENABLE_SAMBA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --samba)
            ENABLE_SAMBA=true
            shift
            ;;
        --help|-h)
            echo "termiNAS Server Setup v$VERSION"
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --samba    Enable Samba (SMB) support for wbadmin compatibility"
            echo "  --help     Show this help message"
            echo ""
            echo "By default, only SFTP access is enabled for security."
            echo "Use --samba to also enable Samba sharing with strict security settings."
            exit 0
            ;;
        --version|-v)
            echo "termiNAS Server Setup v$VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "Starting termiNAS server setup v$VERSION..."
if [ "$ENABLE_SAMBA" = "true" ]; then
    echo "Samba support: ENABLED"
else
    echo "Samba support: DISABLED (use --samba to enable)"
fi
echo ""

# Check Btrfs filesystem requirement
echo "Checking filesystem requirements..."
if [ ! -d /home ]; then
    echo "ERROR: /home directory does not exist"
    exit 1
fi

HOME_FS=$(df -T /home | tail -1 | awk '{print $2}')
if [ "$HOME_FS" != "btrfs" ]; then
    echo ""
    echo "=========================================="
    echo "ERROR: Btrfs filesystem required"
    echo "=========================================="
    echo ""
    echo "/home is currently on: $HOME_FS"
    echo ""
    echo "termiNAS requires Btrfs for efficient snapshot functionality."
    echo ""
    echo "To fix this:"
    echo "  1. Reinstall Debian with Btrfs for /home partition during installation"
    echo "  2. Or create a Btrfs partition and mount it at /home:"
    echo "     # mkfs.btrfs /dev/sdXY"
    echo "     # mount /dev/sdXY /home"
    echo "     # Add to /etc/fstab for persistence"
    echo ""
    exit 1
fi

echo "✓ Btrfs filesystem detected on /home"
echo ""

# Enable Btrfs quotas on /home filesystem
echo "Enabling Btrfs quotas on /home..."
if btrfs qgroup show /home &>/dev/null; then
    echo "  ✓ Btrfs quotas already enabled"
else
    if btrfs quota enable /home; then
        echo "  ✓ Enabled Btrfs quotas"
        echo "  Note: Quota tracking may take a few minutes to initialize for existing data"
    else
        echo "  ⚠ WARNING: Failed to enable Btrfs quotas"
        echo "  Quota management will not be available"
    fi
fi
echo ""

# Update system
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages (removed rsync, added btrfs-progs)
echo "Installing required packages..."
PACKAGES="openssh-server pwgen cron inotify-tools btrfs-progs fail2ban nftables bc coreutils sshpass smbclient expect"
if [ "$ENABLE_SAMBA" = "true" ]; then
    PACKAGES="$PACKAGES samba samba-common-bin"
    echo "  - Including Samba packages for SMB support"
fi
apt install -y $PACKAGES

# Create backup users group
echo "Creating backupusers group..."
groupadd -f backupusers

# Configure SSH
echo "Configuring SSH..."

# Only modify if not already set
if ! grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
    sed -i 's/#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    echo "  - Set PermitRootLogin to no"
fi

if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then
    sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    echo "  - Enabled PasswordAuthentication"
fi

# Enable internal-sftp subsystem (check if already configured)
if ! grep -q "Subsystem sftp internal-sftp" /etc/ssh/sshd_config; then
    sed -i 's/#*Subsystem sftp.*/Subsystem sftp internal-sftp/' /etc/ssh/sshd_config
    echo "  - Configured internal-sftp subsystem"
fi

# Configure SSH keepalive to prevent long uploads from timing out
if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
    sed -i 's/#*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
    echo "  - Set ClientAliveInterval to 60 seconds"
fi

if ! grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
    sed -i 's/#*ClientAliveCountMax.*/ClientAliveCountMax 120/' /etc/ssh/sshd_config
    echo "  - Set ClientAliveCountMax to 120 (allows 2 hours of inactivity)"
fi

# Add group chroot configuration (only if not already present)
if ! grep -q "Match Group backupusers" /etc/ssh/sshd_config; then
    echo "" >> /etc/ssh/sshd_config
    echo "# termiNAS backup users configuration" >> /etc/ssh/sshd_config
    echo "Match Group backupusers" >> /etc/ssh/sshd_config
    echo "    ChrootDirectory %h" >> /etc/ssh/sshd_config
    echo "    ForceCommand internal-sftp" >> /etc/ssh/sshd_config
    echo "    AllowTcpForwarding no" >> /etc/ssh/sshd_config
    echo "    X11Forwarding no" >> /etc/ssh/sshd_config
    echo "  - Added backupusers chroot configuration"
fi

# Restart SSH
echo "Restarting SSH service..."
systemctl restart ssh

# Configure fail2ban for SSH/SFTP protection
echo "Configuring fail2ban..."

# Detect the correct auth log path
if [ -f /var/log/auth.log ]; then
    AUTH_LOG="/var/log/auth.log"
elif [ -f /var/log/secure ]; then
    AUTH_LOG="/var/log/secure"
else
    # Create auth.log if it doesn't exist
    touch /var/log/auth.log
    AUTH_LOG="/var/log/auth.log"
fi

if [ ! -f /etc/fail2ban/jail.d/terminas-sshd.conf ]; then
    cat > /etc/fail2ban/jail.d/terminas-sshd.conf <<F2B
# termiNAS fail2ban configuration for SSH/SFTP protection
# This protects both SSH and SFTP since SFTP uses SSH authentication

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $AUTH_LOG
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600
banaction = nftables[type=multiport]

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = $AUTH_LOG
backend = systemd
maxretry = 10
bantime = 600
findtime = 60
banaction = nftables[type=multiport]
F2B
    echo "  - Created fail2ban SSH/SFTP jail configuration (using $AUTH_LOG)"
else
    echo "  - fail2ban SSH/SFTP jail configuration already exists"
fi

# Create sshd-ddos filter for connection flooding protection
if [ ! -f /etc/fail2ban/filter.d/sshd-ddos.conf ]; then
    cat > /etc/fail2ban/filter.d/sshd-ddos.conf <<'FILTER'
# termiNAS filter for SSH/SFTP DOS (connection flooding) protection
# Detects rapid connection attempts that may indicate a DOS attack
[Definition]
failregex = ^.*Did not receive identification string from <HOST>.*$
            ^.*Connection closed by <HOST> port \d+ \[preauth\].*$
            ^.*Connection reset by <HOST> port \d+ \[preauth\].*$
            ^.*SSH: Server;Ltype: Version;Remote: <HOST>-\d+;.*$
ignoreregex =
FILTER
    echo "  - Created sshd-ddos filter"
fi

# Create custom filter for SFTP-specific issues if needed
if [ ! -f /etc/fail2ban/filter.d/terminas-sftp.conf ]; then
    cat > /etc/fail2ban/filter.d/terminas-sftp.conf <<'FILTER'
# termiNAS custom filter for SFTP abuse
[Definition]
failregex = ^.*subsystem request for sftp.*Failed password for .* from <HOST>.*$
            ^.*subsystem request for sftp.*Connection closed by authenticating user .* <HOST>.*\[preauth\]$
ignoreregex =
FILTER
    echo "  - Created custom SFTP abuse filter"
fi

# Configure nftables action defaults (chain priority and blocktype)
if [ ! -f /etc/fail2ban/action.d/nftables-common.local ]; then
    cat > /etc/fail2ban/action.d/nftables-common.local <<'NFTCOMMON'
# termiNAS fail2ban nftables configuration
# Override default nftables action parameters for better performance

[Init]
# Set chain priority to -100 (earlier in packet processing than default "filter - 1")
# This ensures fail2ban rules are evaluated early for better performance
chain_priority = -100

# Use reject to send RST packets (faster connection failures for legitimate clients)
blocktype = reject
NFTCOMMON
    echo "  - Created nftables-common.local configuration"
fi

# Enable and start fail2ban
echo "Starting fail2ban service..."
systemctl enable fail2ban
systemctl restart fail2ban
echo "  - fail2ban is now protecting SSH/SFTP:"
echo "    * 5 failed login attempts = 1 hour ban"
echo "    * 10 connection attempts in 60s = 10 minute ban (DOS protection)"
echo "    * Applies to both SSH and SFTP connections"

# Configure Samba if enabled
if [ "$ENABLE_SAMBA" = "true" ]; then
    echo "Configuring Samba..."
    
    # Create Samba configuration directory for user-specific configs
    mkdir -p /etc/samba/smb.conf.d
    
    # Backup original smb.conf if it exists
    if [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.bak ]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
        echo "  - Backed up original smb.conf"
    fi
    
    # Create main Samba configuration with security settings
    cat > /etc/samba/smb.conf <<SMB
# termiNAS Samba configuration - STRICT SECURITY SETTINGS
[global]
   workgroup = WORKGROUP
   server string = termiNAS Backup Server
   security = user
   map to guest = never
   
   # Strict protocol requirements
   server min protocol = SMB3
   client min protocol = SMB3
   server max protocol = SMB3
   client max protocol = SMB3
   
   # Encryption required
   smb encrypt = required
   
   # Disable insecure features
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   show add printer wizard = no
   
   # Disable usershares since we use global shares
   usershare max shares = 0
   usershare allow guests = no
   usershare owner only = no
   
   # Suppress quota warnings (optional)
   get quota command = 
   set quota command =
   
   # Logging
   syslog only = yes
   log file = /var/log/samba/log.%m
   max log size = 1000
   # Log level 3 auth:5 ensures authentication failures are logged
   # auth:5 = detailed authentication logging for fail2ban detection
   log level = 3 auth:5
   
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_KEEPALIVE
   read raw = yes
   write raw = yes
   oplocks = yes
   max xmit = 65535
   dead time = 15
   
   # macOS Time Machine support (VFS fruit module)
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

SMB
    
    # Add explicit includes for each per-user config file
    # This ensures all shares in per-user files are loaded (wildcards have limitations)
    echo "" >> /etc/samba/smb.conf
    echo "# Explicit includes for per-user configurations" >> /etc/samba/smb.conf
    if [ -d /etc/samba/smb.conf.d ]; then
        for user_conf in /etc/samba/smb.conf.d/*.conf; do
            if [ -f "$user_conf" ]; then
                echo "include = $user_conf" >> /etc/samba/smb.conf
            fi
        done
    fi
    
    cat >> /etc/samba/smb.conf <<'SMB2'

# Note: Per-user config files in /etc/samba/smb.conf.d/ are included above
# To add new users: run create_user.sh or manage_users.sh enable-samba
# The include list is automatically updated when users are added/removed
SMB2
    
    # Configure fail2ban for Samba protection
    # Create custom filter that works with both auth logs and audit logs
    cat > /etc/fail2ban/filter.d/terminas-samba.conf <<'FILTER'
# termiNAS fail2ban filter for Samba - AUTOMATICALLY CONFIGURED
# This file is automatically generated by termiNAS setup.sh
# MANUAL CHANGES WILL BE OVERWRITTEN when setup.sh is re-run
# 
# Matches authentication failures from Samba logs (log level 2+)
# Authentication failures are logged to /var/log/samba/log.<ip> files

[Definition]
# Match authentication failures with NT_STATUS errors
# The IP is extracted from "remote host [ipv4:IP:port]" in the Auth line
# Log format: 
#   [2025/10/16 18:45:37.752262,  2] ../../auth/auth_log.c:647(log_authentication_event_human_readable)
#     Auth: [SMB2,(null)] user [...] status [NT_STATUS_NO_SUCH_USER] ... remote host [ipv4:202.61.225.34:44202]
# Note: Auth line starts with spaces (continuation of previous line), not timestamp
failregex = ^\s+Auth:.*status\s*\[NT_STATUS_(?:WRONG_PASSWORD|NO_SUCH_USER|LOGON_FAILURE|ACCESS_DENIED)\].*remote host \[ipv4:<HOST>:\d+\]

# Ignore successful authentications
ignoreregex = NT_STATUS_OK
FILTER
    echo "  - Created/updated fail2ban Samba filter"
    
    # Create custom nftables action for Samba (without port filtering)
    # This is needed because tcp dport filtering breaks nftables blocking for some reason
    cat > /etc/fail2ban/action.d/nftables-terminas.conf <<'ACTION'
# Fail2Ban nftables action for Samba - WITHOUT port filtering
# This is a workaround for the issue where tcp dport filtering breaks blocking
#
# Based on nftables.conf but overrides to use simple IP-based blocking

[INCLUDES]
before = nftables.conf

[Definition]

# Force type to custom so we don't get port-based matching
type = custom

# Override match to be empty (no port/protocol filtering)
rule_match-custom = 

# Override rule_stat to use simple IP-based blocking
rule_stat = <addr_family> saddr @<addr_set> <blocktype>
ACTION
    echo "  - Created custom nftables action for Samba"
    
    # Configure fail2ban jail
    cat > /etc/fail2ban/jail.d/terminas-samba.conf <<F2B
# termiNAS fail2ban configuration for Samba protection
# Monitors Samba log files for authentication failures
[terminas-samba]
enabled = true
port = 445
filter = terminas-samba
# Monitor per-IP log files - Samba logs to /var/log/samba/log.<ip>
# Use polling backend to detect new log files created by new connections
logpath = /var/log/samba/log.*[0-9]
backend = polling
maxretry = 5
bantime = 3600
findtime = 600
banaction = nftables-terminas
F2B
    echo "  - Created/updated fail2ban Samba jail configuration"
    
    # Always restart fail2ban when Samba is enabled to pick up filter updates
    echo "Reloading fail2ban with Samba protection..."
    systemctl restart fail2ban
    echo "  - fail2ban Samba jail is now active"
    
    # Configure Samba audit logging (journald)
    echo "  - Samba VFS audit logging configured (using journald)"
    echo "  - View audit logs with: journalctl SYSLOG_IDENTIFIER=smbd_audit"
    
    # Enable and start Samba services
    echo "Starting Samba services..."
    systemctl enable smbd nmbd
    systemctl restart smbd nmbd
    echo "  - Samba is now running with strict security:"
    echo "    * SMB3 protocol only (no older insecure versions)"
    echo "    * Encryption required for all connections"
    echo "    * fail2ban protection (5 failed attempts = 1 hour ban)"
    echo "    * VFS audit logging for connection tracking and security"
    echo "    * User-specific shares with restricted permissions"
    echo "    * VFS audit logging enabled for connection tracking"
fi

# Create base directories
echo "Creating base directories..."
mkdir -p /var/terminas/scripts

# Create monitor script for real-time incremental snapshots
echo "Creating/updating monitor script..."

# Detect git commit hash at setup time
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -d "$REPO_ROOT/.git" ]; then
    TERMINAS_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    TERMINAS_VERSION="git-$TERMINAS_COMMIT"
else
    TERMINAS_COMMIT="unknown"
    TERMINAS_VERSION="non-git"
fi

cat > /var/terminas/scripts/terminas-monitor.sh <<EOF
#!/bin/bash
# Real-time monitor script for user backups
# Watches /home and filters events under uploads/ so new users/uploads are picked up even after start
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas
#
# Generated by setup.sh at $(date '+%F %T')
# Version: $TERMINAS_VERSION
# Commit: $TERMINAS_COMMIT

LOG=/var/log/terminas.log
mkdir -p "\$(dirname "\$LOG")"
touch "\$LOG"
chown root:adm "\$LOG" 2>/dev/null || true
chmod 640 "\$LOG" 2>/dev/null || true

# Log version information on startup
echo "\$(date '+%F %T') ========================================" >> "\$LOG"
echo "\$(date '+%F %T') termiNAS Monitor Service Started" >> "\$LOG"
echo "\$(date '+%F %T') Version: $TERMINAS_VERSION" >> "\$LOG"
echo "\$(date '+%F %T') Commit: $TERMINAS_COMMIT" >> "\$LOG"
echo "\$(date '+%F %T') ========================================" >> "\$LOG"

# Watch /home recursively and react to close_write events
# IMPORTANT: Exclude /home/<user>/versions/ directories to prevent holding file descriptors
# that would block Btrfs extent cleaner from reclaiming space after snapshot deletion
# Pattern: ^/home/[^/]+/versions(/|$) matches /home/<user>/versions/ but NOT /home/<user>/uploads/versions/
# close_write: fired when a file is written and closed
# This captures both direct uploads and atomic uploads (temp files)
# Strategy: Debounce with inactivity window to coalesce multiple uploads
inotifywait -m -r /home --exclude '^/home/[^/]+/versions(/|$)' -e close_write --format '%w%f %e' |
while read path event; do
    # Log ALL events for debugging (will be noisy but helpful)
    echo "\$(date '+%F %T') Raw event: path=\$path, event=\$event" >> "\$LOG"
    
    # Only handle events that happen inside an uploads directory
    case "\$path" in
        */uploads|*/uploads/*)
            ;;
        *)
            echo "\$(date '+%F %T') Event ignored (not in uploads): path=\$path" >> "\$LOG"
            continue
            ;;
    esac

    # Extract username from path: /home/<user>/uploads/...
    user=\$(echo "\$path" | awk -F/ '{print \$3}')
    if [ -z "\$user" ]; then
        continue
    fi

    if [ ! -d "/home/\$user/uploads" ]; then
        # uploads dir might have been removed
        continue
    fi
    
    # Log detected event for debugging
    echo "\$(date '+%F %T') Event detected: user=\$user, path=\$path, event=\$event" >> "\$LOG"
    
    # Strategy: Debounced snapshots
    # - Record activity timestamp when file event occurs
    # - Wait for inactivity period (no new events) before creating snapshot
    # - This coalesces multiple file uploads into a single snapshot
    # - Also support periodic snapshots if uploads are ongoing for a long time
    
    INACTIVITY_WINDOW=\${TERMINAS_INACTIVITY_WINDOW:-60}  # 60 seconds of no activity
    SNAPSHOT_INTERVAL=\${TERMINAS_SNAPSHOT_INTERVAL:-1800}  # 30 minutes max wait
    
    # Track per-user: when did we last see activity, and when did we last snapshot
    runstamp_dir=/var/run/terminas
    mkdir -p "\$runstamp_dir"
    activity_file="\$runstamp_dir/activity_\$user"
    snapshot_file="\$runstamp_dir/snapshot_\$user"
    processing_file="\$runstamp_dir/processing_\$user"
    
    now=\$(date +%s)
    
    # Update activity timestamp (we just saw a file event)
    echo "\$now" > "\$activity_file" 2>/dev/null || true
    
    # Check if a monitor process is already running for this user
    if [ -f "\$processing_file" ]; then
        # Check if the PID in the file is still running
        old_pid=\$(cat "\$processing_file" 2>/dev/null)
        if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null; then
            # Process is still alive, monitor already running
            continue
        else
            # Stale lock file from crashed/killed process, remove it
            echo "\$(date '+%Y-%m-%d %H:%M:%S') Removing stale lock file for user \$user (PID \$old_pid no longer exists)" >> /var/log/terminas.log
            rm -f "\$processing_file"
        fi
    fi
    
    # Spawn a single background monitor process for this user
    # This process will keep checking for inactivity and create snapshot when ready
    # Only ONE process per user, regardless of how many files are uploaded
    (
        # Inherit LOG variable in subshell
        LOG="\$LOG"
        
        # Mark that we're monitoring this user
        monitor_pid=\$BASHPID
        echo "\$monitor_pid" > "\$processing_file" 2>/dev/null || true
        
        # Keep monitoring until inactivity window is reached
        while true; do
            sleep 5  # Check every 5 seconds
            
            # Get last activity timestamp
            last_activity=\$(cat "\$activity_file" 2>/dev/null || echo 0)
            current_time=\$(date +%s)
            idle_time=\$((current_time - last_activity))
            
            # If we've been idle for the inactivity window, create snapshot
            if [ "\$idle_time" -ge "\$INACTIVITY_WINDOW" ]; then
                break
            fi
            
            # Safety: if we've been running for more than SNAPSHOT_INTERVAL, force snapshot
            if [ "\$idle_time" -ge "\$SNAPSHOT_INTERVAL" ]; then
                echo "\$(date '+%F %T') User \$user: forcing snapshot after \$SNAPSHOT_INTERVAL seconds" >> "\$LOG"
                break
            fi
        done
        
        # Ready to create snapshot after inactivity period
        snapshot_reason="upload complete (no activity for \${idle_time}s)"
        
        # Check if any files are still open (in-progress uploads)
        open_files=\$(lsof +D "/home/\$user/uploads" 2>/dev/null | grep -E "\\s+[0-9]+[uw]" | wc -l || echo 0)
        if [ "\$open_files" -gt 0 ]; then
            snapshot_reason="forced snapshot (\$open_files files still open)"
        fi
        
        # Check if uploads directory has files
        if [ ! -d "/home/\$user/uploads" ]; then
            echo "\$(date '+%F %T') Skipping snapshot for \$user: uploads subvolume does not exist" >> "\$LOG"
            exit 0
        fi
        
        if [ -z "\$(ls -A "/home/\$user/uploads" 2>/dev/null)" ]; then
            echo "\$(date '+%F %T') Skipping snapshot for \$user: uploads directory is empty" >> "\$LOG"
            exit 0
        fi
        
        # Check quota before creating snapshot
        # Note: Btrfs quotas are enforced at filesystem level, so even if we allow the
        # snapshot here, Btrfs will reject it if it would exceed quota. This pre-check
        # provides clearer logging for administrators.
        if btrfs qgroup show /home &>/dev/null; then
            # Get subvolume ID for uploads subvolume and check quota
            subvol_id=\$(btrfs subvolume show "/home/\$user/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\\s+\\K[0-9]+' || echo "")
            
            if [ -n "\$subvol_id" ]; then
                qgroup_id="1/\$subvol_id"
                
                # Get quota usage (raw bytes)
                qgroup_info=\$(btrfs qgroup show --raw /home 2>/dev/null | grep "^\${qgroup_id}\\s" || echo "")
                used_bytes=\$(echo "\$qgroup_info" | awk '{print \$2}')
                
                # Get quota limit (need -re flag to show limit columns)
                limit_info=\$(btrfs qgroup show --raw -re /home 2>/dev/null | grep "^\${qgroup_id}\\s" || echo "")
                limit_bytes=\$(echo "\$limit_info" | awk '{print \$4}')
                
                if [ -n "\$qgroup_info" ]; then
                    # Parse: qgroupid rfer excl (from qgroup_info)
                    # And: qgroupid rfer excl max_rfer max_excl (from limit_info)
                    
                    # Check if limit is set
                    if [ "\$limit_bytes" != "0" ] && [ "\$limit_bytes" != "none" ] && [ -n "\$limit_bytes" ]; then
                        # Calculate available space
                        available_bytes=\$((limit_bytes - used_bytes))
                        
                        # Reject snapshot if already at or over quota
                        if [ "\$available_bytes" -le 0 ]; then
                            # Over quota - reject snapshot
                            used_gb=\$(echo "scale=2; \$used_bytes / 1024 / 1024 / 1024" | bc)
                            limit_gb=\$(echo "scale=2; \$limit_bytes / 1024 / 1024 / 1024" | bc)
                            echo "\$(date '+%F %T') ERROR: User \$user is at/over quota (\${used_gb}GB / \${limit_gb}GB)" >> "\$LOG"
                            echo "\$(date '+%F %T') Snapshot creation blocked - user must free up space" >> "\$LOG"
                            rm -f "\$processing_file" 2>/dev/null || true
                            exit 0
                        fi
                        
                        # Note: We cannot accurately predict snapshot size before creation due to
                        # Btrfs Copy-on-Write. Snapshots initially share blocks with uploads subvolume
                        # (minimal space), only diverging as files are modified. Btrfs will enforce
                        # quota at filesystem level if snapshot would exceed limit.
                        
                        # Check warning threshold
                        usage_pct=\$(echo "scale=1; (\$used_bytes / \$limit_bytes) * 100" | bc)
                        if [ \$(echo "\$usage_pct > 90" | bc) -eq 1 ]; then
                            used_gb=\$(echo "scale=2; \$used_bytes / 1024 / 1024 / 1024" | bc)
                            limit_gb=\$(echo "scale=2; \$limit_bytes / 1024 / 1024 / 1024" | bc)
                            available_gb=\$(echo "scale=2; \$available_bytes / 1024 / 1024 / 1024" | bc)
                            echo "\$(date '+%F %T') WARNING: User \$user approaching quota limit (\${used_gb}GB / \${limit_gb}GB, \${usage_pct}%, \${available_gb}GB available)" >> "\$LOG"
                        fi
                    fi
                fi
            fi
        fi
        
        # Force filesystem sync to ensure all buffered data is written to disk
        sync
        
        timestamp=\$(date +%Y-%m-%d_%H-%M-%S)
        snapshot_path="/home/\$user/versions/\$timestamp"
        
        # Strategy for excluding in-progress files:
        # 1. Create writable snapshot first (no -r flag)
        # 2. Delete any files that are currently open for writing
        # 3. Make snapshot read-only for ransomware protection
        
        if btrfs subvolume snapshot "/home/\$user/uploads" "\$snapshot_path" >> "\$LOG" 2>&1; then
            # Snapshot created, now exclude in-progress files
            excluded_count=0
            
            # Find files that are currently open for writing in the ORIGINAL uploads dir
            open_files_list=\$(lsof +D "/home/\$user/uploads" 2>/dev/null | grep -E "\\s+[0-9]+[uw]" | awk '{print \$NF}' || true)
            
            if [ -n "\$open_files_list" ]; then
                echo "\$(date '+%F %T') Excluding in-progress files from snapshot:" >> "\$LOG"
                while IFS= read -r open_file; do
                    if [ -n "\$open_file" ] && [ -f "\$open_file" ]; then
                        # Extract relative path from /home/user/uploads/...
                        rel_path=\${open_file#/home/\$user/uploads/}
                        snapshot_file_path="\$snapshot_path/\$rel_path"
                        
                        if [ -f "\$snapshot_file_path" ]; then
                            rm -f "\$snapshot_file_path"
                            excluded_count=\$((excluded_count + 1))
                            file_size=\$(du -h "\$open_file" 2>/dev/null | awk '{print \$1}' || echo "?")
                            echo "\$(date '+%F %T')   Excluded: \$rel_path (\${file_size}, still uploading)" >> "\$LOG"
                        fi
                    fi
                done <<< "\$open_files_list"
            fi
            
            # Now make the snapshot read-only (ransomware protection)
            btrfs property set -ts "\$snapshot_path" ro true >> "\$LOG" 2>&1 || true
            
            # Set ownership and permissions
            chown root:backupusers "\$snapshot_path" 2>/dev/null || true
            chmod 755 "\$snapshot_path" 2>/dev/null || true
            
            # Log snapshot details
            if [ "\$excluded_count" -gt 0 ]; then
                echo "\$(date '+%F %T') Btrfs snapshot created for \$user at \$timestamp (\$snapshot_reason, excluded \$excluded_count in-progress files)" >> "\$LOG"
            else
                echo "\$(date '+%F %T') Btrfs snapshot created for \$user at \$timestamp (\$snapshot_reason)" >> "\$LOG"
            fi
        else
            echo "\$(date '+%F %T') ERROR: Failed to create Btrfs snapshot for \$user" >> "\$LOG"
        fi
        
        # Record last snapshot time
        echo "\$now_check" > "\$snapshot_file" 2>/dev/null || true
        
        # Clean up processing lock so future uploads can trigger new snapshots
        rm -f "\$processing_file" 2>/dev/null || true
    ) &  # End subprocess, run in background
done
EOF

chmod +x /var/terminas/scripts/terminas-monitor.sh

# Create systemd unit for the monitor (preserve Environment variables if service exists)
echo "Installing systemd unit for backup monitor..."
if [ -f /etc/systemd/system/terminas-monitor.service ]; then
    # Extract existing Environment variables
    existing_env=$(grep "^Environment=" /etc/systemd/system/terminas-monitor.service 2>/dev/null || true)
    cat > /etc/systemd/system/terminas-monitor.service <<'UNIT'
[Unit]
Description=termiNAS real-time backup monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /var/terminas/scripts/terminas-monitor.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    # Re-add any existing Environment variables
    if [ -n "$existing_env" ]; then
        # Insert Environment lines after [Service] line
        sed -i "/^\[Service\]/a $existing_env" /etc/systemd/system/terminas-monitor.service
        echo "  - Preserved existing environment variables"
    fi
else
    cat > /etc/systemd/system/terminas-monitor.service <<'UNIT'
[Unit]
Description=termiNAS real-time backup monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /var/terminas/scripts/terminas-monitor.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable terminas-monitor.service
systemctl restart terminas-monitor.service

# Tune inotify max_user_watches to support many users/directories
if [ ! -f /etc/sysctl.d/99-terminas-inotify.conf ]; then
    echo "Configuring inotify limits..."
    echo "fs.inotify.max_user_watches=524288" > /etc/sysctl.d/99-terminas-inotify.conf
    sysctl --system >/dev/null 2>&1 || true
fi

# Add logrotate config for the monitor log
echo "Configuring log rotation..."
cat > /etc/logrotate.d/terminas <<'LR'
/var/log/terminas.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root adm
}
LR

# Create retention policy configuration file (only if it doesn't exist)
if [ ! -f /etc/terminas-retention.conf ]; then
    echo "Creating retention policy configuration..."
    cat > /etc/terminas-retention.conf <<'CONF'
# termiNAS Retention Policy Configuration
# Edit this file to customize snapshot retention

# Default retention mode: advanced (recommended)
# Set to 'false' to use simple age-based retention
ENABLE_ADVANCED_RETENTION=true

# Simple age-based retention (days) - used when ENABLE_ADVANCED_RETENTION=false
# Snapshots older than this will be deleted
RETENTION_DAYS=30

# Advanced retention policy (Grandfather-Father-Son strategy)
# Keep: last N daily, last M weekly, last Y monthly snapshots
KEEP_DAILY=7        # Keep last 7 daily snapshots
KEEP_WEEKLY=4       # Keep last 4 weekly snapshots (one per week)
KEEP_MONTHLY=6      # Keep last 6 monthly snapshots (one per month)

# Per-user overrides (optional)
# Format: USERNAME_KEEP_DAILY=N, USERNAME_KEEP_WEEKLY=M, USERNAME_KEEP_MONTHLY=Y
# Example:
#   produser_KEEP_DAILY=30
#   produser_KEEP_WEEKLY=12
#   produser_KEEP_MONTHLY=24
#   testuser_RETENTION_DAYS=7
#   testuser_ENABLE_ADVANCED_RETENTION=false

# Run cleanup at this hour (0-23)
CLEANUP_HOUR=3

# ============================================================================
# Quota Configuration
# ============================================================================
# Btrfs quotas limit total disk usage (uploads + all snapshots) per user
# Quotas are disabled by default when creating users (unlimited storage)

# Default quota for new users (in GB, 0 = unlimited)
DEFAULT_QUOTA_GB=0

# Per-user quota overrides (in GB)
# Example:
#   testuser_QUOTA_GB=50
#   produser_QUOTA_GB=500

# Quota warning threshold (percentage)
# Log warning when user reaches this % of quota
QUOTA_WARN_THRESHOLD=90
CONF
else
    echo "Retention policy configuration already exists, preserving existing settings"
fi

# Create/update cleanup script with configurable retention
echo "Creating/updating cleanup script..."
cat > /var/terminas/scripts/terminas-cleanup.sh <<'EOF'
#!/bin/bash
# Cleanup old snapshots based on retention policy
# Configuration: /etc/terminas-retention.conf
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Load configuration
if [ -f /etc/terminas-retention.conf ]; then
    source /etc/terminas-retention.conf
else
    # Defaults if config file is missing
    RETENTION_DAYS=30
    ENABLE_ADVANCED_RETENTION=false
fi

LOG=/var/log/terminas.log

log_msg() {
    echo "$(date '+%F %T') [CLEANUP] $*" >> "$LOG"
}

# Simple age-based cleanup
cleanup_by_age() {
    log_msg "Running age-based cleanup (keeping last $RETENTION_DAYS days)"
    local count=0
    while IFS= read -r -d '' snapshot; do
        # Check if it's a Btrfs subvolume before deleting
        if btrfs subvolume show "$snapshot" &>/dev/null; then
            # Make snapshot writable before deletion
            btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
            btrfs subvolume delete "$snapshot" &>/dev/null && count=$((count + 1))
        else
            # Fallback for non-subvolume directories (shouldn't happen in Btrfs setup)
            rm -rf "$snapshot" && count=$((count + 1))
        fi
    done < <(find /home -mindepth 2 -maxdepth 3 -type d -path '*/versions/*' -mtime +$RETENTION_DAYS -print0 2>/dev/null)
    log_msg "Removed $count snapshots older than $RETENTION_DAYS days"
}

# Advanced retention: keep daily, weekly, monthly snapshots
cleanup_advanced() {
    log_msg "Running advanced retention cleanup (default: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY)"
    
    # Get list of backup users (both primary group members and supplementary group members)
    local gid=$(getent group backupusers 2>/dev/null | cut -d: -f3)
    local users=""
    
    # Get users whose primary group is backupusers
    if [ -n "$gid" ]; then
        users=$(getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}')
    fi
    
    # Also get users who have backupusers as supplementary group
    local supp_users=$(getent group backupusers 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    if [ -n "$supp_users" ]; then
        users=$(echo -e "$users\n$supp_users" | sort -u)
    fi
    
    while IFS= read -r user; do
        [ -z "$user" ] && continue
        local versions_dir="/home/$user/versions"
        [ ! -d "$versions_dir" ] && continue
        
        # Check for per-user retention settings
        # Sanitize username for variable names (replace hyphens with underscores)
        local user_safe="${user//-/_}"
        local user_daily_var="${user_safe}_KEEP_DAILY"
        local user_weekly_var="${user_safe}_KEEP_WEEKLY"
        local user_monthly_var="${user_safe}_KEEP_MONTHLY"
        local user_daily=${!user_daily_var:-$KEEP_DAILY}
        local user_weekly=${!user_weekly_var:-$KEEP_WEEKLY}
        local user_monthly=${!user_monthly_var:-$KEEP_MONTHLY}
        
        if [ "$user_daily" != "$KEEP_DAILY" ] || [ "$user_weekly" != "$KEEP_WEEKLY" ] || [ "$user_monthly" != "$KEEP_MONTHLY" ]; then
            log_msg "User $user: using custom retention (daily=$user_daily, weekly=$user_weekly, monthly=$user_monthly)"
        fi
        
        # Get all snapshots sorted by date (newest first)
        local snapshots=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
        [ -z "$snapshots" ] && continue
        
        # Arrays to track what to keep
        declare -A keep_snapshots
        local snapshot_array=()
        while IFS= read -r s; do
            [ -n "$s" ] && snapshot_array+=("$s")
        done <<< "$snapshots"
        
        # GFS (Grandfather-Father-Son) retention strategy:
        # 1. Keep last N daily snapshots (recent backups)
        # 2. Keep one snapshot per week for N weeks (excluding dailies)
        # 3. Keep one snapshot per month for N months (excluding dailies and weeklies)
        
        # Mark last N daily snapshots
        local daily_count=0
        for snapshot in "${snapshot_array[@]}"; do
            [ $daily_count -ge $user_daily ] && break
            keep_snapshots["$snapshot"]="daily"
            daily_count=$((daily_count + 1))
        done
        
        # Mark last N weekly snapshots (one per week, skip if already kept as daily)
        local weekly_count=0
        local last_week=""
        for snapshot in "${snapshot_array[@]}"; do
            [ $weekly_count -ge $user_weekly ] && break
            [ -n "${keep_snapshots[$snapshot]}" ] && continue  # Already kept as daily
            
            # Extract date from snapshot name (format: YYYY-MM-DD_HH-MM-SS)
            local snap_date=$(basename "$snapshot" | cut -d_ -f1)
            local week=$(date -d "$snap_date" +%Y-W%U 2>/dev/null || echo "")
            if [ -n "$week" ] && [ "$week" != "$last_week" ]; then
                keep_snapshots["$snapshot"]="weekly"
                last_week="$week"
                weekly_count=$((weekly_count + 1))
            fi
        done
        
        # Mark last N monthly snapshots (one per month, skip if already kept as daily/weekly)
        local monthly_count=0
        local last_month=""
        for snapshot in "${snapshot_array[@]}"; do
            [ $monthly_count -ge $user_monthly ] && break
            [ -n "${keep_snapshots[$snapshot]}" ] && continue  # Already kept as daily/weekly
            
            local snap_date=$(basename "$snapshot" | cut -d_ -f1)
            local month=$(date -d "$snap_date" +%Y-%m 2>/dev/null || echo "")
            if [ -n "$month" ] && [ "$month" != "$last_month" ]; then
                keep_snapshots["$snapshot"]="monthly"
                last_month="$month"
                monthly_count=$((monthly_count + 1))
            fi
        done
        
        # Remove snapshots not in keep list
        local removed=0
        local kept=0
        for snapshot in "${snapshot_array[@]}"; do
            local snap_name=$(basename "$snapshot")
            if [ -z "${keep_snapshots[$snapshot]}" ]; then
                # Check if it's a Btrfs subvolume before deleting
                if btrfs subvolume show "$snapshot" &>/dev/null; then
                    # Make snapshot writable before deletion
                    btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
                    if btrfs subvolume delete "$snapshot" &>/dev/null; then
                        log_msg "User $user: deleted snapshot $snap_name"
                        removed=$((removed + 1))
                    fi
                else
                    # Fallback for non-subvolume directories (shouldn't happen)
                    if rm -rf "$snapshot"; then
                        log_msg "User $user: deleted snapshot $snap_name"
                        removed=$((removed + 1))
                    fi
                fi
            else
                kept=$((kept + 1))
            fi
        done
        
        if [ $removed -gt 0 ] || [ $kept -gt 0 ]; then
            log_msg "User $user: kept $kept snapshots, removed $removed snapshots"
        fi
    done <<< "$users"
}

# Main cleanup logic
if [ "$ENABLE_ADVANCED_RETENTION" = "true" ]; then
    cleanup_advanced
else
    cleanup_by_age
fi

log_msg "Cleanup completed"
EOF
chmod +x /var/terminas/scripts/terminas-cleanup.sh

# Install daily cron job for cleanup (run at configured hour) - only if not already present
if ! crontab -l 2>/dev/null | grep -q "terminas-cleanup.sh"; then
    echo "Installing cleanup cron job..."
    (crontab -l 2>/dev/null; echo "0 3 * * * /var/terminas/scripts/terminas-cleanup.sh") | crontab -
else
    echo "Cleanup cron job already exists"
fi

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Create backup users: ./create_user.sh <username>"
echo "  2. Monitor logs: tail -f /var/log/terminas.log"
echo "  3. Check service: systemctl status terminas-monitor.service"
echo "  4. Manage users: ./manage_users.sh list"
echo ""
echo "Configuration files:"
echo "  - Retention policy: /etc/terminas-retention.conf"
echo "  - Monitor service: /etc/systemd/system/terminas-monitor.service"
echo "  - Scripts: /var/terminas/scripts/"
echo "  - Log file: /var/log/terminas.log"
echo ""