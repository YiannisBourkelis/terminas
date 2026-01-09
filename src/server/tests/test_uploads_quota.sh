#!/bin/bash

# test_uploads_quota.sh - Fast quota enforcement test for termiNAS
# Usage: ./test_uploads_quota.sh [--cleanup-only]
#
# This is a quick test that verifies quota enforcement works without waiting
# for snapshots. It creates a user with 1GB quota, uploads a 500MB file
# (should succeed), then tries to upload a 1GB file (should fail with
# "Disk quota exceeded").
#
# Quota Architecture:
# - Level-0 qgroup on uploads subvolume for fast quota enforcement
# - Hybrid mode: total usage (uploads + snapshots) checked after each snapshot
# - If over total quota, uploads are blocked until user deletes files
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

set -e

# Test configuration
TEST_USER="terminas_test_uploads_quota"
TEST_QUOTA_GB=1  # 1GB quota for testing
TEST_FILES_DIR="/var/tmp/terminas_test_uploads"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory (tests folder) and parent directory (server scripts)
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Function to print section header
print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Function to print test result
print_result() {
    local result="$1"
    local message="$2"
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS:${NC} $message"
    elif [ "$result" = "FAIL" ]; then
        echo -e "${RED}✗ FAIL:${NC} $message"
    elif [ "$result" = "INFO" ]; then
        echo -e "${YELLOW}ℹ INFO:${NC} $message"
    fi
}

# Function to cleanup test user
cleanup_test_user() {
    print_header "Cleaning up test user: $TEST_USER"
    
    if id "$TEST_USER" &>/dev/null; then
        echo "Deleting test user (non-interactive)..."
        "$SCRIPT_DIR/delete_user.sh" --force "$TEST_USER" 2>/dev/null || true
        print_result "INFO" "Test user deleted"
    else
        print_result "INFO" "Test user does not exist, nothing to cleanup"
    fi
    
    # Remove test files directory
    rm -rf "$TEST_FILES_DIR" 2>/dev/null || true
    
    echo ""
}

# Parse command line arguments
CLEANUP_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup-only|--cleanup|--clean-up-only|--cleanuponly)
            CLEANUP_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--cleanup-only]"
            echo ""
            echo "Fast quota enforcement test - no snapshot waiting."
            echo "Creates user with 1GB quota, tests file upload blocking."
            echo ""
            echo "Options:"
            echo "  --cleanup-only   Only cleanup the test user, don't run tests"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--cleanup-only]" >&2
            exit 1
            ;;
    esac
done

# Handle cleanup-only mode
if [ "$CLEANUP_ONLY" = true ]; then
    cleanup_test_user
    echo -e "${GREEN}Cleanup completed.${NC}"
    exit 0
fi

# Start tests
print_header "termiNAS Fast Quota Enforcement Test"
echo "Test user: $TEST_USER"
echo "Quota limit: ${TEST_QUOTA_GB}GB"
echo ""

# Cleanup any existing test user first
cleanup_test_user

# Check prerequisites
print_header "Checking Prerequisites"

if ! btrfs qgroup show /home &>/dev/null; then
    print_result "FAIL" "Btrfs quotas not enabled on /home"
    echo "Run: btrfs quota enable /home"
    exit 1
fi
print_result "PASS" "Btrfs quotas enabled on /home"

# Check for qgroup data inconsistency (critical - can cause kernel hangs during writes)
echo "Checking qgroup data consistency..."
qgroup_output=$(btrfs qgroup show /home 2>&1)
if echo "$qgroup_output" | grep -qi "qgroup data inconsistent"; then
    print_result "FAIL" "Qgroup data is inconsistent - quota operations may hang!"
    echo ""
    echo -e "${YELLOW}The Btrfs qgroup data is inconsistent and needs a rescan.${NC}"
    echo -e "${YELLOW}Without this, file writes to quota-enabled directories may hang.${NC}"
    echo ""
    echo "To fix, run:"
    echo "  sudo btrfs quota rescan /home"
    echo "  # Wait for completion with:"
    echo "  sudo btrfs quota rescan -s /home"
    echo "  # (repeat -s until it shows 'no rescan operation in progress')"
    echo ""
    echo "Or run rescan and wait automatically:"
    echo "  sudo btrfs quota rescan -w /home"
    echo ""
    read -p "Would you like to run a quota rescan now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Starting quota rescan (this may take a while for large filesystems)..."
        btrfs quota rescan -w /home
        print_result "PASS" "Quota rescan completed"
    else
        echo "Aborting test. Please run the rescan manually before testing."
        exit 1
    fi
else
    print_result "PASS" "Qgroup data is consistent"
fi

# Wait for any ongoing quota rescan to complete (critical for quota enforcement)
echo "Checking for ongoing quota rescan..."
rescan_status=$(btrfs quota rescan -s /home 2>&1)
if echo "$rescan_status" | grep -qi "running\|progress"; then
    echo "Quota rescan is in progress. Waiting for completion..."
    echo "(This may take a while for large filesystems)"
    btrfs quota rescan -w /home 2>/dev/null || true
    print_result "PASS" "Quota rescan completed"
elif echo "$rescan_status" | grep -qi "no rescan"; then
    print_result "PASS" "No quota rescan in progress"
else
    # Unknown status, continue anyway
    print_result "INFO" "Quota rescan status: $rescan_status"
fi

if [ ! -f "$SCRIPT_DIR/create_user.sh" ]; then
    print_result "FAIL" "create_user.sh not found in $SCRIPT_DIR"
    exit 1
fi
print_result "PASS" "Server scripts found"

# Create test files directory
mkdir -p "$TEST_FILES_DIR"

# TEST 1: Create test user with quota
print_header "TEST 1/4: Create Test User with ${TEST_QUOTA_GB}GB Quota"

echo "Creating user $TEST_USER with ${TEST_QUOTA_GB}GB quota..."
if "$SCRIPT_DIR/create_user.sh" "$TEST_USER" --quota "${TEST_QUOTA_GB}" > /tmp/create_user_output.txt 2>&1; then
    print_result "PASS" "User created successfully"
else
    print_result "FAIL" "Failed to create user"
    cat /tmp/create_user_output.txt
    exit 1
fi

# Verify quota is set
echo "Verifying quota configuration..."
# The show-quota output format is "Limit: X.XXGB" under "Total Quota" section
if "$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" 2>&1 | grep -q "Limit: ${TEST_QUOTA_GB}"; then
    print_result "PASS" "Quota limit correctly set to ${TEST_QUOTA_GB}GB"
else
    print_result "FAIL" "Quota limit not set correctly"
    "$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER"
    exit 1
fi

# Wait for any quota rescan triggered by user creation to complete
echo "Waiting for quota rescan to complete (if any)..."
rescan_status=$(btrfs quota rescan -s /home 2>&1)
if echo "$rescan_status" | grep -qi "running\|progress"; then
    echo "  Quota rescan in progress, waiting..."
    btrfs quota rescan -w /home 2>/dev/null || true
    print_result "PASS" "Quota rescan completed"
else
    print_result "INFO" "No rescan in progress"
fi

# TEST 2: Upload 500MB file (should succeed)
print_header "TEST 2/4: Upload 500MB File (Should Succeed)"

# Debug: Show qgroup status before copy
echo "Debug: Checking qgroup status..."
if [ -f "/home/$TEST_USER/.terminas-qgroup" ]; then
    uploads_qgroup=$(cat "/home/$TEST_USER/.terminas-qgroup")
    echo "  Uploads qgroup: $uploads_qgroup"
    
    # Show quota info for this qgroup
    echo "  Quota info:"
    btrfs qgroup show -r /home 2>/dev/null | grep -E "^${uploads_qgroup}\s|Qgroupid" | head -5
    
    # Verify this is a level-0 qgroup (should be 0/xxx format)
    if [[ "$uploads_qgroup" == 0/* ]]; then
        print_result "PASS" "Using level-0 qgroup on uploads subvolume (fast mode)"
    else
        print_result "INFO" "Qgroup format: $uploads_qgroup"
    fi
fi

echo "Creating 500MB test file with random data..."
TEST_FILE_500MB="$TEST_FILES_DIR/test_500mb.dat"
dd if=/dev/urandom of="$TEST_FILE_500MB" bs=10M count=50 status=progress 2>&1 | grep -v records || true

if [ ! -f "$TEST_FILE_500MB" ]; then
    print_result "FAIL" "Failed to create 500MB test file"
    exit 1
fi

actual_size=$(du -m "$TEST_FILE_500MB" | cut -f1)
print_result "INFO" "Created test file: ${actual_size}MB"

echo "Copying 500MB file to uploads directory..."

# Use timeout (should be fast with level-0 quotas, but protect against edge cases)
if timeout 30 cp "$TEST_FILE_500MB" "/home/$TEST_USER/uploads/" 2>/tmp/cp_error.txt; then
    chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_500mb.dat"
    print_result "PASS" "500MB file uploaded successfully (as expected)"
else
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
        print_result "FAIL" "Copy timed out after 30 seconds"
        echo ""
        echo "Debug: This may indicate a Btrfs qgroup issue."
        echo "Check: btrfs quota rescan -s /home"
        echo "Check: btrfs qgroup show -r /home"
        echo ""
        echo "If qgroup data is inconsistent, run a rescan:"
        echo "  btrfs quota rescan -w /home"
    else
        print_result "FAIL" "500MB file upload failed unexpectedly (exit code: $exit_code)"
        cat /tmp/cp_error.txt
    fi
    cleanup_test_user
    exit 1
fi

# Rescan quota and show usage
echo "Updating quota accounting..."
btrfs quota rescan -w /home 2>/dev/null || true

"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" 2>&1 | head -20
echo ""

# TEST 3: Upload 1GB file (should fail - quota exceeded)
print_header "TEST 3/4: Upload 1GB File (Should Be Blocked)"

echo "Creating 1GB test file with random data..."
TEST_FILE_1GB="$TEST_FILES_DIR/test_1gb.dat"
dd if=/dev/urandom of="$TEST_FILE_1GB" bs=10M count=100 status=progress 2>&1 | grep -v records || true

if [ ! -f "$TEST_FILE_1GB" ]; then
    print_result "FAIL" "Failed to create 1GB test file"
    exit 1
fi

actual_size=$(du -m "$TEST_FILE_1GB" | cut -f1)
print_result "INFO" "Created test file: ${actual_size}MB"

echo "Attempting to copy 1GB file to uploads directory..."
echo "(This should fail with 'Disk quota exceeded')"
echo ""

if cp "$TEST_FILE_1GB" "/home/$TEST_USER/uploads/" 2>/tmp/cp_error.txt; then
    # File was copied - quota not enforced!
    print_result "FAIL" "1GB file was copied - QUOTA NOT ENFORCED!"
    echo ""
    echo "This indicates the quota system is not working correctly."
    echo "The file copy should have been blocked by Btrfs."
    echo ""
    
    # Show quota status for debugging
    "$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER"
    
    # Show qgroup details for debugging
    echo ""
    echo "Qgroup details (raw):"
    
    # Read uploads qgroup from config file
    uploads_qgroup=""
    if [ -f "/home/$TEST_USER/.terminas-qgroup" ]; then
        uploads_qgroup=$(cat "/home/$TEST_USER/.terminas-qgroup" 2>/dev/null)
    fi
    echo "Uploads qgroup (from config): $uploads_qgroup"
    
    uploads_subvol_id=$(btrfs subvolume show "/home/$TEST_USER/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "unknown")
    echo "Uploads subvolume ID: $uploads_subvol_id"
    
    echo ""
    echo "Uploads qgroup (level-0 quota):"
    btrfs qgroup show -r /home 2>/dev/null | head -1
    btrfs qgroup show -r /home 2>/dev/null | grep -E "^${uploads_qgroup}|^0/${uploads_subvol_id}" || echo "  (not found)"
    
    echo ""
    echo "Note: Quota is enforced on the uploads subvolume (level-0 qgroup) for fast enforcement"
    echo "      Hybrid mode checks total usage (uploads + snapshots) after each snapshot"
    
    TEST_RESULT="FAIL"
else
    # File copy failed - check if it's due to quota
    if grep -q "Disk quota exceeded" /tmp/cp_error.txt; then
        print_result "PASS" "1GB file upload blocked: Disk quota exceeded"
        TEST_RESULT="PASS"
    else
        print_result "FAIL" "File copy failed for unexpected reason:"
        cat /tmp/cp_error.txt
        TEST_RESULT="FAIL"
    fi
fi

# Verify the 1GB file was NOT copied
if [ -f "/home/$TEST_USER/uploads/test_1gb.dat" ]; then
    actual_copied=$(du -m "/home/$TEST_USER/uploads/test_1gb.dat" | cut -f1)
    print_result "INFO" "Warning: Partial file may exist (${actual_copied}MB)"
fi

# TEST 4: Show final quota status
print_header "TEST 4/4: Final Quota Status"

"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER"

# Summary
print_header "Test Summary"

if [ "$TEST_RESULT" = "PASS" ]; then
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  QUOTA ENFORCEMENT TEST: PASSED       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo "✓ 500MB file upload: Succeeded (within quota)"
    echo "✓ 1GB file upload: Blocked (exceeded quota)"
    echo ""
    echo "Quota enforcement is working correctly!"
else
    echo -e "${RED}═══════════════════════════════════════${NC}"
    echo -e "${RED}  QUOTA ENFORCEMENT TEST: FAILED       ${NC}"
    echo -e "${RED}═══════════════════════════════════════${NC}"
    echo ""
    echo "Quota enforcement is NOT working."
    echo "Please check the Btrfs qgroup configuration."
fi

echo ""

# Cleanup
print_header "Cleanup"
cleanup_test_user

echo -e "${GREEN}Test completed.${NC}"

if [ "$TEST_RESULT" = "PASS" ]; then
    exit 0
else
    exit 1
fi
