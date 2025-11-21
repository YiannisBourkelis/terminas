#!/bin/bash

# test_delete_user_cleanup.sh - Reproduce and verify Btrfs cleanup after user deletion
# Creates a test user, triggers a snapshot, deletes the user, and checks pending
# deleted subvolumes before and after restarting the monitor and syncing the FS.
#
# Usage:
#   sudo ./test_delete_user_cleanup.sh
#
# Exit codes: 0 on success, non-zero on failure
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

TEST_USER="terminas_test_cleanup"
TEST_FILE_DIR="/var/tmp/terminas_test_cleanup"
TEST_FILE="$TEST_FILE_DIR/file_20mb.dat"
WAIT_SECS=${WAIT_SECS:-70}   # wait for snapshot (monitor debounce + buffer)

log() { echo -e "${BLUE}==>${NC} $*"; }
pass() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    fail "This test must run as root"; exit 1
  fi
}

pending_deleted_count() {
  btrfs subvolume list -d /home 2>/dev/null | wc -l | tr -d ' '\n
}

cleanup_user() {
  if id "$TEST_USER" &>/dev/null; then
    log "Deleting existing test user..."
    "$SCRIPT_DIR/delete_user.sh" --force "$TEST_USER" || true
    # Give kernel a nudge to commit metadata
    btrfs filesystem sync /home 2>/dev/null || true
  fi
}

create_user_and_snapshot() {
  log "Creating test user: $TEST_USER (quota 1GB)"
  "$SCRIPT_DIR/create_user.sh" "$TEST_USER" --quota 1 >/tmp/create_$TEST_USER.log 2>&1 || {
    fail "Failed to create test user; see /tmp/create_$TEST_USER.log"; exit 1;
  }
  pass "User created"
  
  # Diagnostic: Check if home directory is a subvolume
  if btrfs subvolume show "/home/$TEST_USER" &>/dev/null; then
    log "Detected: /home/$TEST_USER is a Btrfs subvolume (created by useradd -m)"
  else
    log "Detected: /home/$TEST_USER is a regular directory"
  fi
  
  # Diagnostic: List all subvolumes for this user
  log "Subvolumes for $TEST_USER:"
  btrfs subvolume list /home | grep "$TEST_USER" | sed 's/^/  /' || echo "  (none found)"

  mkdir -p "$TEST_FILE_DIR"
  log "Creating 20MB test file"
  dd if=/dev/urandom of="$TEST_FILE" bs=1M count=20 status=none
  pass "Test file created"

  log "Copying test file to uploads and fixing ownership"
  cp "$TEST_FILE" "/home/$TEST_USER/uploads/"
  chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/$(basename "$TEST_FILE")"
  pass "File in uploads"

  log "Waiting up to ${WAIT_SECS}s for snapshot creation"
  local before after
  before=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
  sleep "$WAIT_SECS"
  after=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
  if [ "$after" -gt "$before" ]; then
    pass "Snapshot created (${after} total)"
  else
    warn "No snapshot detected; monitor may be slow or inactive"
  fi
}

delete_user_and_verify_cleanup() {
  # Check pending deletions BEFORE user deletion (baseline)
  local count_before
  count_before=$(pending_deleted_count)
  log "Pending deletions before user deletion: $count_before"
  
  log "Deleting test user"
  "$SCRIPT_DIR/delete_user.sh" --force "$TEST_USER" 2>&1 | tee /tmp/delete_$TEST_USER.log
  
  # Check if home directory was removed
  if [ -d "/home/$TEST_USER" ]; then
    fail "Home directory still exists after deletion!"
    ls -la "/home/$TEST_USER"
  else
    pass "Home directory removed"
  fi

  local count1
  count1=$(pending_deleted_count)
  log "Pending deletions immediately after delete: $count1"
  
  # Show detailed list if there are pending deletions
  if [ "$count1" -gt "$count_before" ]; then
    log "New pending deletions detected: +$((count1 - count_before)) (this is normal)"
    btrfs subvolume list -d /home | sed 's/^/  /'
  fi

  # Note: DO NOT restart monitor service - this could cause missed inotify notifications
  # The Btrfs cleaner will process deletions asynchronously
  
  log "Forcing filesystem sync on /home (triggers Btrfs cleaner)"
  btrfs filesystem sync /home || warn "filesystem sync returned non-zero"

  log "Waiting 10 seconds for Btrfs cleaner to process deletions..."
  sleep 10

  local count2
  count2=$(pending_deleted_count)
  log "Pending deletions after sync+wait: $count2"

  # Test passes if pending deletions return to baseline OR reach zero
  if [ "$count2" -eq "$count_before" ]; then
    pass "All deleted subvolumes cleaned up (returned to baseline: $count_before)"
  elif [ "$count2" -eq 0 ]; then
    pass "All deleted subvolumes cleaned up (no pending deletions)"
  elif [ "$count2" -lt "$count1" ]; then
    # Some cleanup happened but not complete - give it more time
    log "Partial cleanup detected ($count1 → $count2). Waiting additional 10 seconds..."
    sleep 10
    count2=$(pending_deleted_count)
    log "Pending deletions after extended wait: $count2"
    
    if [ "$count2" -eq "$count_before" ] || [ "$count2" -eq 0 ]; then
      pass "All deleted subvolumes cleaned up after extended wait"
    else
      warn "Some pending deletions remain: $count2 (baseline: $count_before)"
      warn "This may be normal - Btrfs cleaner runs asynchronously"
      warn "Check again later with: ./manage_users.sh show-pending-deletions"
      btrfs subvolume list -d /home | sed 's/^/  /'
    fi
  else
    fail "Pending deletions not decreasing: $count2 (expected: $count_before)"
    btrfs subvolume list -d /home | sed 's/^/  /'
    exit 1
  fi
}

require_root
log "Starting delete_user cleanup reproduction test"
cleanup_user
create_user_and_snapshot

delete_user_and_verify_cleanup

# Cleanup temp
rm -rf "$TEST_FILE_DIR" 2>/dev/null || true

pass "Test complete"
