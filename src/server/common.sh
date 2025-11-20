#!/bin/bash

# common.sh - Shared functions for termiNAS server scripts
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Function to validate password strength
# Returns 0 if valid, 1 if invalid
# Usage: validate_password "password"
validate_password() {
    local password="$1"
    local length=${#password}
    
    # Check minimum length (30 characters)
    if [ "$length" -lt 30 ]; then
        echo "ERROR: Password must be at least 30 characters long (provided: $length characters)" >&2
        return 1
    fi
    
    # Check for lowercase letters
    if ! echo "$password" | grep -q '[a-z]'; then
        echo "ERROR: Password must contain at least one lowercase letter" >&2
        return 1
    fi
    
    # Check for uppercase letters
    if ! echo "$password" | grep -q '[A-Z]'; then
        echo "ERROR: Password must contain at least one uppercase letter" >&2
        return 1
    fi
    
    # Check for numbers
    if ! echo "$password" | grep -q '[0-9]'; then
        echo "ERROR: Password must contain at least one number" >&2
        return 1
    fi
    
    return 0
}

# Function to check if Samba is installed
# Returns 0 if installed, 1 if not
has_samba_installed() {
    command -v smbpasswd &>/dev/null
}

# Function to check if a user has Samba enabled
# Returns 0 if enabled, 1 if not
# Usage: has_samba_enabled "username"
has_samba_enabled() {
    local username="$1"
    [ -f "/etc/samba/smb.conf.d/$username.conf" ]
}

# Function to check if a user has Time Machine enabled
# Returns 0 if enabled, 1 if not
# Usage: has_timemachine_enabled "username"
has_timemachine_enabled() {
    local username="$1"
    if [ -f "/etc/samba/smb.conf.d/$username.conf" ]; then
        grep -q "^\[$username-timemachine\]" "/etc/samba/smb.conf.d/$username.conf"
    else
        return 1
    fi
}

# Function to get list of backup users (users in backupusers group)
# Prints usernames one per line
get_backup_users() {
    getent group backupusers | cut -d: -f4 | tr ',' '\n' | grep -v '^$'
}

# Function to check if user is a backup user
# Returns 0 if user is backup user, 1 if not
# Usage: is_backup_user "username"
is_backup_user() {
    local username="$1"
    groups "$username" 2>/dev/null | grep -q "backupusers"
}
