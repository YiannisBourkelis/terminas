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

# Parse quota values with optional unit suffix.
# - raw: input string (e.g., "50", "50GB", "13000MB", or legacy bytes when default_unit="B")
# - default_unit: unit to assume when no suffix is provided (GB by default). Accepts GB, MB, or B.
# Returns: "bytes|amount|unit|display" on success; non-zero on failure.
parse_quota_value() {
    local raw="$1"
    local default_unit="${2:-GB}"

    local normalized="${raw,,}"
    normalized="${normalized// /}"

    local amount=""
    local unit=""

    if [[ "$normalized" =~ ^([0-9]+)mb$ ]]; then
        amount="${BASH_REMATCH[1]}"
        unit="MB"
    elif [[ "$normalized" =~ ^([0-9]+)gb$ ]]; then
        amount="${BASH_REMATCH[1]}"
        unit="GB"
    elif [[ "$normalized" =~ ^([0-9]+)$ ]]; then
        amount="$normalized"
        case "${default_unit^^}" in
            MB) unit="MB" ;;
            B) unit="B" ;;
            *) unit="GB" ;;
        esac
    else
        return 1
    fi

    local bytes=0
    case "$unit" in
        MB) bytes=$((amount * 1024 * 1024)) ;;
        B)  bytes=$amount ;;
        *)  bytes=$((amount * 1024 * 1024 * 1024)) ;;
    esac

    local display="$(format_quota_display "$bytes")"
    echo "${bytes}|${amount}|${unit}|${display}"
    return 0
}

# Format bytes into a human-friendly quota string (prefers GB, falls back to MB).
format_quota_display() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0GB"
        return 0
    fi
    local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    # If at least 0.01 GB, show GB with 2 decimals; otherwise show MB rounded.
    if echo "$gb >= 0.01" | bc -l >/dev/null 2>&1 && [ "$(echo "$gb >= 0.01" | bc)" -eq 1 ]; then
        printf "%.2fGB" "$gb"
    else
        local mb=$(echo "scale=0; $bytes / 1024 / 1024" | bc 2>/dev/null || echo "0")
        printf "%sMB" "$mb"
    fi
}

# Function to check if user is a backup user
# Returns 0 if user is backup user, 1 if not
# Usage: is_backup_user "username"
is_backup_user() {
    local username="$1"
    groups "$username" 2>/dev/null | grep -q "backupusers"
}
