#!/bin/bash

# migrate_quota_to_level1.sh - One-time migration script for Btrfs quota architecture
# 
# This script migrates existing users from the old quota architecture (level-0 qgroups
# on home directory) to the new level-1 qgroup hierarchy per Btrfs documentation.
#
# The new architecture:
# - Level-1 qgroup (1/UID) is created for each user
# - Uploads subvolume is assigned to the user's level-1 qgroup
# - All existing snapshots are assigned to the user's level-1 qgroup
# - Quota limit is set on the level-1 qgroup
#
# This script can be safely deleted after migration is complete.
#
# Usage: sudo ./migrate_quota_to_level1.sh [username]
#        sudo ./migrate_quota_to_level1.sh --all
#
# See: https://btrfs.readthedocs.io/en/latest/Qgroups.html (Multi-user machine section)
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0 [username|--all]"
    exit 1
fi

# Check if Btrfs quotas are enabled
if ! btrfs qgroup show /home &>/dev/null; then
    echo -e "${RED}ERROR: Btrfs quotas are not enabled on /home${NC}"
    echo "Run: btrfs quota enable /home"
    exit 1
fi

# Get list of backup users
get_backup_users() {
    local gid=$(getent group backupusers 2>/dev/null | cut -d: -f3)
    if [ -z "$gid" ]; then
        return
    fi
    
    # Find users with backupusers as primary group
    local primary_users=$(getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}')
    
    # Find users with backupusers as supplementary group
    local supp_users=$(getent group backupusers 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    
    # Combine and deduplicate
    echo -e "${primary_users}\n${supp_users}" | grep -v '^$' | sort -u
}

# Migrate a single user to level-1 qgroup architecture
migrate_user() {
    local username="$1"
    local home_dir="/home/$username"
    
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Migrating user: $username${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}ERROR: User '$username' does not exist${NC}"
        return 1
    fi
    
    # Check if user is a backup user
    if ! groups "$username" 2>/dev/null | grep -q "backupusers"; then
        echo -e "${YELLOW}SKIP: User '$username' is not a backup user${NC}"
        return 0
    fi
    
    # Check if home directory exists
    if [ ! -d "$home_dir" ]; then
        echo -e "${RED}ERROR: Home directory '$home_dir' does not exist${NC}"
        return 1
    fi
    
    # Check if already migrated (has .terminas-qgroup with level-1 qgroup)
    if [ -f "$home_dir/.terminas-qgroup" ]; then
        existing_qgroup=$(cat "$home_dir/.terminas-qgroup" 2>/dev/null)
        if [[ "$existing_qgroup" == 1/* ]]; then
            echo -e "${GREEN}✓ Already migrated (qgroup: $existing_qgroup)${NC}"
            return 0
        fi
    fi
    
    # Get user's UID for level-1 qgroup
    local user_uid=$(id -u "$username")
    local user_qgroup="1/$user_uid"
    
    echo "  User UID: $user_uid"
    echo "  Target qgroup: $user_qgroup"
    
    # Step 1: Create level-1 qgroup if it doesn't exist
    echo ""
    echo "Step 1: Creating level-1 qgroup..."
    if btrfs qgroup show /home 2>/dev/null | grep -q "^${user_qgroup}\s"; then
        echo -e "  ${GREEN}✓ Level-1 qgroup already exists${NC}"
    else
        if btrfs qgroup create "$user_qgroup" /home 2>/dev/null; then
            echo -e "  ${GREEN}✓ Created level-1 qgroup: $user_qgroup${NC}"
        else
            echo -e "  ${RED}ERROR: Failed to create level-1 qgroup${NC}"
            return 1
        fi
    fi
    
    # Step 2: Assign uploads subvolume to level-1 qgroup
    echo ""
    echo "Step 2: Assigning uploads subvolume..."
    if [ -d "$home_dir/uploads" ]; then
        local uploads_subvol_id=$(btrfs subvolume show "$home_dir/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
        if [ -n "$uploads_subvol_id" ]; then
            local uploads_qgroup="0/$uploads_subvol_id"
            if btrfs qgroup assign "$uploads_qgroup" "$user_qgroup" /home 2>/dev/null; then
                echo -e "  ${GREEN}✓ Assigned uploads ($uploads_qgroup) to $user_qgroup${NC}"
            else
                # May fail if already assigned, which is fine
                echo -e "  ${YELLOW}⚠ Could not assign uploads (may already be assigned)${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠ Uploads is not a Btrfs subvolume${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ No uploads directory found${NC}"
    fi
    
    # Step 3: Assign all existing snapshots to level-1 qgroup
    echo ""
    echo "Step 3: Assigning existing snapshots..."
    local snapshot_count=0
    local assigned_count=0
    if [ -d "$home_dir/versions" ]; then
        for snapshot in "$home_dir/versions"/*; do
            if [ -d "$snapshot" ]; then
                snapshot_count=$((snapshot_count + 1))
                local snapshot_subvol_id=$(btrfs subvolume show "$snapshot" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
                if [ -n "$snapshot_subvol_id" ]; then
                    local snapshot_qgroup="0/$snapshot_subvol_id"
                    if btrfs qgroup assign "$snapshot_qgroup" "$user_qgroup" /home 2>/dev/null; then
                        assigned_count=$((assigned_count + 1))
                    fi
                fi
            fi
        done
        echo -e "  ${GREEN}✓ Assigned $assigned_count of $snapshot_count snapshots${NC}"
    else
        echo -e "  ${YELLOW}⚠ No versions directory found${NC}"
    fi
    
    # Step 4: Check for existing quota and migrate it
    echo ""
    echo "Step 4: Migrating quota limit..."
    local old_quota_bytes=""
    
    # Check if there was a quota on the old level-0 qgroup (home directory)
    local home_subvol_id=$(btrfs subvolume show "$home_dir" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
    if [ -n "$home_subvol_id" ]; then
        local old_qgroup="0/$home_subvol_id"
        local old_limit_info=$(btrfs qgroup show --raw -re /home 2>/dev/null | grep "^${old_qgroup}\s" || echo "")
        if [ -n "$old_limit_info" ]; then
            old_quota_bytes=$(echo "$old_limit_info" | awk '{print $5}')
            if [ "$old_quota_bytes" != "0" ] && [ "$old_quota_bytes" != "none" ] && [ -n "$old_quota_bytes" ]; then
                # Set the same limit on new level-1 qgroup
                if btrfs qgroup limit "$old_quota_bytes" "$user_qgroup" /home 2>/dev/null; then
                    local old_quota_gb=$(echo "scale=2; $old_quota_bytes / 1024 / 1024 / 1024" | bc)
                    echo -e "  ${GREEN}✓ Migrated quota limit: ${old_quota_gb}GB${NC}"
                    
                    # Remove old limit from level-0 qgroup
                    btrfs qgroup limit none "$old_qgroup" /home 2>/dev/null || true
                else
                    echo -e "  ${YELLOW}⚠ Could not migrate quota limit${NC}"
                fi
            else
                echo -e "  ${GREEN}✓ No quota limit was set (unlimited)${NC}"
            fi
        else
            echo -e "  ${GREEN}✓ No existing quota to migrate${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ Could not determine home subvolume ID${NC}"
    fi
    
    # Step 5: Create/update .terminas-qgroup config file
    echo ""
    echo "Step 5: Updating configuration..."
    echo "$user_qgroup" > "$home_dir/.terminas-qgroup"
    chown root:root "$home_dir/.terminas-qgroup"
    chmod 644 "$home_dir/.terminas-qgroup"
    echo -e "  ${GREEN}✓ Saved qgroup config: $home_dir/.terminas-qgroup${NC}"
    
    echo ""
    echo -e "${GREEN}✓ Migration complete for user '$username'${NC}"
    return 0
}

# Main script
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  termiNAS Quota Migration Tool${NC}"
echo -e "${BLUE}  Migrating to Level-1 Qgroup Architecture${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "This script migrates existing users to the new hierarchical qgroup"
echo "architecture per Btrfs documentation. This is a one-time migration."
echo ""
echo "Reference: https://btrfs.readthedocs.io/en/latest/Qgroups.html"
echo ""

if [ $# -lt 1 ]; then
    echo "Usage: $0 <username>     - Migrate a single user"
    echo "       $0 --all          - Migrate all backup users"
    echo ""
    echo "Available backup users:"
    get_backup_users | while read user; do
        if [ -n "$user" ]; then
            if [ -f "/home/$user/.terminas-qgroup" ]; then
                qg=$(cat "/home/$user/.terminas-qgroup" 2>/dev/null)
                if [[ "$qg" == 1/* ]]; then
                    echo "  - $user (already migrated: $qg)"
                else
                    echo "  - $user (needs migration, old qgroup: $qg)"
                fi
            else
                echo "  - $user (needs migration, no qgroup config)"
            fi
        fi
    done
    exit 0
fi

if [ "$1" = "--all" ]; then
    echo "Migrating all backup users..."
    
    users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo -e "${YELLOW}No backup users found${NC}"
        exit 0
    fi
    
    total=0
    success=0
    skipped=0
    failed=0
    
    while IFS= read -r user; do
        if [ -n "$user" ]; then
            total=$((total + 1))
            if migrate_user "$user"; then
                # Check if it was skipped (already migrated) or successful
                if [ -f "/home/$user/.terminas-qgroup" ]; then
                    qg=$(cat "/home/$user/.terminas-qgroup" 2>/dev/null)
                    if [[ "$qg" == 1/* ]]; then
                        success=$((success + 1))
                    fi
                fi
            else
                failed=$((failed + 1))
            fi
        fi
    done <<< "$users"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Migration Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Total users:     $total"
    echo "  Migrated:        $success"
    echo "  Failed:          $failed"
    echo ""
    
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}All users migrated successfully!${NC}"
        echo ""
        echo "You can now safely delete this migration script:"
        echo "  rm $0"
    else
        echo -e "${YELLOW}Some users failed to migrate. Please check the errors above.${NC}"
    fi
else
    migrate_user "$1"
    
    echo ""
    echo "If migration was successful, you can delete this script after"
    echo "migrating all users:"
    echo "  rm $0"
fi

echo ""
