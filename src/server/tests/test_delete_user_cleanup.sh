#!/bin/bash

# test_delete_user_cleanup.sh - Verify Btrfs subvolume deletion after user removal
# Creates a test user, triggers a snapshot, deletes the user, and verifies that
# the Btrfs cleaner can immediately reclaim space.
#
# Root Cause: Background monitoring subprocesses (spawned by terminas-monitor.sh)
# hold file descriptor references to /home/<user>/uploads directories. When a user
# is deleted, if the monitoring subprocess is still running, it blocks the Btrfs
# cleaner from reclaiming space.
#
# Solution: delete_user.sh kills the background monitoring subprocess for the deleted
# user before removing directories, allowing immediate cleanup.
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

  # Note: delete_user.sh should have killed the background monitoring subprocess
  # for this user before deleting directories. No monitor restart needed.
  
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
  else
    # Still have pending deletions - this should NOT happen if subprocess was killed properly
    fail "Pending deletions remain after cleanup: $count2 (expected: $count_before)"
    log "This indicates the background monitoring subprocess was not killed properly"
    btrfs subvolume list -d /home | sed 's/^/  /'
    
    # Check if open file handles exist
    log "Checking for open file handles..."
    if lsof +D /home 2>/dev/null | grep -q "$TEST_USER"; then
      fail "Found open file handles on deleted user directory!"
      lsof +D /home 2>/dev/null | grep "$TEST_USER" | head -n 10 | sed 's/^/  /'
    else
      warn "No open file handles found, but deletions still pending"
      warn "Btrfs cleaner may need more time - this is unusual"
    fi
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
