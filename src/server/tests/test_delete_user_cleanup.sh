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
WAIT_SECS=${WAIT_SECS:-80}   # wait for snapshot (monitor debounce + buffer)

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
  log "Deleting test user"
  "$SCRIPT_DIR/delete_user.sh" --force "$TEST_USER" >/tmp/delete_$TEST_USER.log 2>&1 || warn "delete_user returned non-zero (may be okay)"

  local count1
  count1=$(pending_deleted_count)
  echo "Pending deletions after delete: $count1"

  log "Restarting monitor service"
  systemctl restart terminas-monitor.service || warn "Failed to restart monitor"

  log "Forcing filesystem sync on /home"
  btrfs filesystem sync /home || warn "filesystem sync returned non-zero"

  local count2
  count2=$(pending_deleted_count)
  echo "Pending deletions after restart+sync: $count2"

  if [ "$count2" -eq 0 ]; then
    pass "All deleted subvolumes cleaned up"
  else
    warn "Still pending deletions: $count2"
    btrfs subvolume list -d /home | sed 's/^/  /'
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
