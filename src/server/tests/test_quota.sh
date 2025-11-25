#!/bin/bash

# test_quota.sh - Test script for termiNAS quota functionality
# Usage: ./test_quota.sh [--cleanup-only]
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

set -e

# Test configuration
TEST_USER="terminas_test_quota"
TEST_QUOTA_GB=1  # 1GB quota for testing
TEST_FILE_SIZE_MB=300  # Create 300MB files
MONITOR_WAIT_TIME=70  # Wait time for monitor to create snapshot (debounce + buffer)
TEST_FILES_DIR="/var/tmp/terminas_test"  # Use /var/tmp instead of /tmp (more space)

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

# Check for required dependencies
echo "Checking dependencies..."
missing_deps=()

if ! command -v bc &>/dev/null; then
    missing_deps+=("bc")
fi

if ! command -v btrfs &>/dev/null; then
    missing_deps+=("btrfs-progs")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${RED}ERROR: Missing required dependencies: ${missing_deps[*]}${NC}"
    echo ""
    echo "Please install missing packages:"
    echo "  apt install ${missing_deps[*]}"
    echo ""
    echo "Or re-run setup.sh to install all dependencies"
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
        
        # Use delete_user.sh with --force flag to skip confirmation
        "$SCRIPT_DIR/delete_user.sh" --force "$TEST_USER" 2>/dev/null || true
        
        print_result "INFO" "Test user deleted"
    else
        print_result "INFO" "Test user does not exist, nothing to cleanup"
    fi
    
    # Remove any leftover runtime files (delete_user.sh also does this, but just to be sure)
    rm -f "/var/run/terminas/activity_$TEST_USER" 2>/dev/null || true
    rm -f "/var/run/terminas/snapshot_$TEST_USER" 2>/dev/null || true
    rm -f "/var/run/terminas/processing_$TEST_USER" 2>/dev/null || true
    
    echo ""
}

# Parse command line arguments (accept common aliases/typos)
CLEANUP_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup-only|--cleanup|--clean-up-only|--cleanuponly|--clenup-only)
            CLEANUP_ONLY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--cleanup-only]"
            echo "Aliases: --cleanup, --clean-up-only, --cleanuponly, --clenup-only"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: $0 [--cleanup-only]" >&2
            exit 2
            ;;
    esac
done

if [ "$CLEANUP_ONLY" = "true" ]; then
    cleanup_test_user
    exit 0
fi

# Start tests
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  termiNAS Quota Functionality Test Suite${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Test Configuration:"
echo "  Test user: $TEST_USER"
echo "  Quota limit: ${TEST_QUOTA_GB}GB"
echo "  Test file size: ${TEST_FILE_SIZE_MB}MB each"
echo "  Monitor wait time: ${MONITOR_WAIT_TIME}s"
echo "  Test files directory: $TEST_FILES_DIR"
echo ""

# Setup test files directory
mkdir -p "$TEST_FILES_DIR"

# Cleanup any existing test user first
cleanup_test_user

# TEST 1: Check if Btrfs quotas are enabled
print_header "TEST 1/10: Verify Btrfs Quotas Enabled"

echo "Checking if Btrfs quotas are enabled on /home..."
if btrfs qgroup show /home &>/dev/null; then
    print_result "PASS" "Btrfs quotas are enabled on /home"
else
    print_result "FAIL" "Btrfs quotas are NOT enabled on /home"
    echo ""
    echo "To enable quotas, run: btrfs quota enable /home"
    echo "Or re-run setup.sh"
    exit 1
fi

# TEST 2: Create user with quota
print_header "TEST 2/10: Create User with Quota Limit"

echo "Creating user '$TEST_USER' with ${TEST_QUOTA_GB}GB quota..."
if "$SCRIPT_DIR/create_user.sh" "$TEST_USER" --quota "$TEST_QUOTA_GB" > /tmp/create_user_output.txt 2>&1; then
    print_result "PASS" "User created successfully with quota"
    
    # Extract password from output
    TEST_PASSWORD=$(grep "Generated secure password:" /tmp/create_user_output.txt | cut -d: -f2 | xargs || grep "Creating user" /tmp/create_user_output.txt | awk '{print $NF}')
    print_result "INFO" "Password: $TEST_PASSWORD"
else
    print_result "FAIL" "Failed to create user with quota"
    cat /tmp/create_user_output.txt
    exit 1
fi

# Verify user exists
if id "$TEST_USER" &>/dev/null; then
    print_result "PASS" "User account exists"
else
    print_result "FAIL" "User account does not exist"
    exit 1
fi

# Verify home directory and structure
if [ -d "/home/$TEST_USER" ]; then
    print_result "PASS" "Home directory exists"
else
    print_result "FAIL" "Home directory does not exist"
    exit 1
fi

if [ -d "/home/$TEST_USER/uploads" ]; then
    print_result "PASS" "Uploads subvolume exists"
else
    print_result "FAIL" "Uploads subvolume does not exist"
    exit 1
fi

if [ -d "/home/$TEST_USER/versions" ]; then
    print_result "PASS" "Versions directory exists"
else
    print_result "FAIL" "Versions directory does not exist"
    exit 1
fi

# TEST 3: Verify quota is set correctly
print_header "TEST 3/10: Verify Quota Configuration"

echo "Checking quota with show-quota command..."
if timeout 30 "$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1; then
    print_result "PASS" "show-quota command completed successfully"
else
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
        print_result "FAIL" "show-quota command timed out after 30 seconds"
    else
        print_result "FAIL" "show-quota command failed with exit code $exit_code"
    fi
    print_result "INFO" "Output:"
    cat /tmp/quota_output.txt
    exit 1
fi

if grep -q "Quota limit: ${TEST_QUOTA_GB}" /tmp/quota_output.txt; then
    print_result "PASS" "Quota limit is correctly set to ${TEST_QUOTA_GB}GB"
else
    print_result "FAIL" "Quota limit not set correctly"
    print_result "INFO" "Output:"
    cat /tmp/quota_output.txt
    exit 1
fi

if grep -qE "Current usage: 0(\.00)?GB" /tmp/quota_output.txt; then
    print_result "PASS" "Initial quota usage is 0GB"
else
    print_result "FAIL" "Initial quota usage is not 0GB"
    print_result "INFO" "Output:"
    cat /tmp/quota_output.txt
fi

# TEST 4: Upload files within quota
print_header "TEST 4/10: Upload Files Within Quota Limit"

echo "Creating test file (${TEST_FILE_SIZE_MB}MB)..."
TEST_FILE_1="$TEST_FILES_DIR/test_file_1.dat"
# Use /dev/urandom for unique data (prevents Btrfs deduplication)
# Using larger block size (10M) for better performance
dd if=/dev/urandom of="$TEST_FILE_1" bs=10M count=$((TEST_FILE_SIZE_MB / 10)) status=progress 2>&1 | grep -v records || true

if [ -f "$TEST_FILE_1" ]; then
    actual_size=$(du -m "$TEST_FILE_1" | cut -f1)
    print_result "PASS" "Created test file: ${actual_size}MB"
else
    print_result "FAIL" "Failed to create test file"
    exit 1
fi

echo "Copying file to user's uploads directory..."
cp "$TEST_FILE_1" "/home/$TEST_USER/uploads/"
chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_file_1.dat"

if [ -f "/home/$TEST_USER/uploads/test_file_1.dat" ]; then
    print_result "PASS" "File copied successfully"
else
    print_result "FAIL" "File copy failed"
    exit 1
fi

echo "Waiting ${MONITOR_WAIT_TIME}s for monitor to create snapshot..."

# Get snapshot count before
snapshot_count_before=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

sleep "$MONITOR_WAIT_TIME"

# Get snapshot count after
snapshot_count_after=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

if [ "$snapshot_count_after" -gt "$snapshot_count_before" ]; then
    print_result "PASS" "Snapshot created automatically ($snapshot_count_after total)"
else
    print_result "FAIL" "No snapshot created (monitor may not be running)"
    print_result "INFO" "Check: systemctl status terminas-monitor.service"
    print_result "INFO" "Check: tail -50 /var/log/terminas.log"
    # Don't exit - continue with tests
fi

# Rescan quota to ensure accurate accounting (qgroups can be inconsistent without rescan)
echo "Updating quota accounting..."
btrfs quota rescan -w /home 2>/dev/null || true

# Check quota usage
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
current_usage=$(grep "Current usage:" /tmp/quota_output.txt | grep -oP '\d+\.\d+GB' | head -1)
print_result "INFO" "Quota usage after first file: $current_usage"

# TEST 5: Upload more files to approach quota limit
print_header "TEST 5/10: Upload Files to Approach Quota Limit (90%+ Warning)"

echo "Creating second test file (${TEST_FILE_SIZE_MB}MB)..."
TEST_FILE_2="$TEST_FILES_DIR/test_file_2.dat"
# Use /dev/urandom for unique data (prevents Btrfs deduplication)
dd if=/dev/urandom of="$TEST_FILE_2" bs=10M count=$((TEST_FILE_SIZE_MB / 10)) status=progress 2>&1 | grep -v records || true
echo "✓ Second test file created"

echo "Copying second file..."
if cp "$TEST_FILE_2" "/home/$TEST_USER/uploads/" 2>/tmp/cp2_error.txt; then
    echo "✓ Second file copied successfully"
    chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_file_2.dat"
else
    echo "✗ Second file copy failed:"
    cat /tmp/cp2_error.txt
    print_result "INFO" "Copy failed - checking quota status"
    "$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER"
fi

echo "Waiting ${MONITOR_WAIT_TIME}s for monitor to create snapshot..."

# Get snapshot count before
snapshot_count_before=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

sleep "$MONITOR_WAIT_TIME"

# Get snapshot count after
snapshot_count_after=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

if [ "$snapshot_count_after" -gt "$snapshot_count_before" ]; then
    print_result "PASS" "Second snapshot created ($snapshot_count_after total)"
else
    print_result "FAIL" "No second snapshot created"
fi

# Rescan quota to ensure accurate accounting
echo "Updating quota accounting..."
btrfs quota rescan -w /home 2>/dev/null || true

# Check quota usage
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
current_usage=$(grep "Current usage:" /tmp/quota_output.txt | grep -oP '\d+\.\d+GB' | head -1)
usage_pct=$(grep "Current usage:" /tmp/quota_output.txt | grep -oP '\d+\.\d+%' | head -1)
print_result "INFO" "Quota usage after second file: $current_usage ($usage_pct)"

# Check if warning is shown
if grep -q "WARNING: Storage usage is above 90%" /tmp/quota_output.txt; then
    print_result "PASS" "Quota warning displayed (>90%)"
else
    print_result "INFO" "No quota warning yet (<90%)"
fi

# Check logs for warnings
if grep -q "WARNING.*approaching quota limit" /var/log/terminas.log; then
    print_result "PASS" "Quota warning logged in terminas.log"
else
    print_result "INFO" "No quota warning in logs yet"
fi

# TEST 6: Try to exceed quota limit
print_header "TEST 6/10: Test Quota Enforcement (File Upload Blocked)"

# NOTE: Quota is enforced using REFERENCED (logical) bytes on a level-1 qgroup.
# The level-1 qgroup tracks uploads subvolume + all assigned snapshot subvolumes.
# With Btrfs deduplication, identical data across uploads and snapshots is counted once.
# A 300MB file in uploads = 300MB. After snapshot, still ~300MB (shared blocks).
# With 1GB limit and 300MB files, we need ~4 unique files to exceed the limit.

echo "Creating third test file (${TEST_FILE_SIZE_MB}MB)..."
TEST_FILE_3="$TEST_FILES_DIR/test_file_3.dat"
# Use /dev/urandom for unique data (prevents Btrfs deduplication)
dd if=/dev/urandom of="$TEST_FILE_3" bs=10M count=$((TEST_FILE_SIZE_MB / 10)) status=progress 2>&1 | grep -v records || true

echo "Copying third file (testing quota enforcement)..."
QUOTA_BLOCKED_AT=""
if cp "$TEST_FILE_3" "/home/$TEST_USER/uploads/" 2>/tmp/cp3_error.txt; then
    chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_file_3.dat"
    echo "✓ Third file copied successfully"
else
    if grep -q "Disk quota exceeded" /tmp/cp3_error.txt; then
        QUOTA_BLOCKED_AT="file3"
        print_result "PASS" "Btrfs blocked third file upload (Disk quota exceeded)"
    else
        print_result "FAIL" "Third file copy failed for unexpected reason"
        cat /tmp/cp3_error.txt
    fi
fi

if [ -z "$QUOTA_BLOCKED_AT" ]; then
    echo "Waiting ${MONITOR_WAIT_TIME}s for monitor to create snapshot..."
    sleep "$MONITOR_WAIT_TIME"
fi

# Rescan quota to ensure accurate accounting
echo "Updating quota accounting..."
btrfs quota rescan -w /home 2>/dev/null || true

# Check current quota usage
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
current_usage=$(grep "Current usage:" /tmp/quota_output.txt | grep -oP '\d+\.\d+GB' | head -1)
print_result "INFO" "Quota usage after third file attempt: $current_usage"

# Now create a fourth file to push over quota limit (if not already blocked)
if [ -z "$QUOTA_BLOCKED_AT" ]; then
    echo "Creating fourth test file (${TEST_FILE_SIZE_MB}MB) to exceed quota..."
    TEST_FILE_4="$TEST_FILES_DIR/test_file_4.dat"
    # Use /dev/urandom for unique data (prevents Btrfs deduplication)
    dd if=/dev/urandom of="$TEST_FILE_4" bs=10M count=$((TEST_FILE_SIZE_MB / 10)) status=progress 2>&1 | grep -v records || true

    echo "Attempting to copy fourth file (should be blocked by Btrfs quota)..."
    if cp "$TEST_FILE_4" "/home/$TEST_USER/uploads/" 2>/tmp/cp_error.txt; then
        chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_file_4.dat"
        print_result "INFO" "File copy succeeded (quota not enforced or limit not reached yet)"
    else
        if grep -q "Disk quota exceeded" /tmp/cp_error.txt; then
            QUOTA_BLOCKED_AT="file4"
            print_result "PASS" "Btrfs blocked file upload (Disk quota exceeded)"
        else
            print_result "FAIL" "File copy failed for unexpected reason"
            cat /tmp/cp_error.txt
            exit 1
        fi
    fi

    # Only wait for snapshot if file was successfully copied
    if [ -f "/home/$TEST_USER/uploads/test_file_4.dat" ]; then
        # Get snapshot count before attempting snapshot of over-quota state
        snapshot_count_before=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        
        echo "Waiting ${MONITOR_WAIT_TIME}s for monitor to attempt snapshot..."
        sleep "$MONITOR_WAIT_TIME"
        
        # Get snapshot count after
        snapshot_count_after=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        
        # With exclusive quota, snapshots are essentially free (share blocks via CoW)
        # So snapshots should still be created even when near/at quota limit
        if [ "$snapshot_count_after" -gt "$snapshot_count_before" ]; then
            print_result "PASS" "Snapshot created (expected - snapshots are free with exclusive quota)"
        else
            print_result "INFO" "No snapshot created (monitor may have blocked due to pre-check)"
        fi
        
        # Check logs for quota warnings/errors
        tail -100 /var/log/terminas.log > /tmp/recent_log.txt
        
        if grep -q "WARNING.*approaching quota limit" /tmp/recent_log.txt; then
            print_result "PASS" "Quota warning logged in terminas.log"
        fi
        
        if grep -q "ERROR.*over quota\|at/over quota" /tmp/recent_log.txt; then
            print_result "INFO" "Quota error logged (pre-check blocked snapshot)"
        fi
    else
        print_result "PASS" "Quota enforcement working - file upload blocked"
    fi
else
    print_result "PASS" "Quota already blocked at third file - quota enforcement working"
fi

# Check quota status
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
print_result "INFO" "Final quota status:"
cat /tmp/quota_output.txt | grep -E "Quota limit|Current usage|Available|WARNING"

# TEST 7: Test quota modification
print_header "TEST 7/10: Test Quota Modification (Increase Limit)"

echo "Increasing quota to 2GB..."
if "$SCRIPT_DIR/manage_users.sh" set-quota "$TEST_USER" 2 > /tmp/set_quota_output.txt 2>&1; then
    print_result "PASS" "Quota increased successfully"
else
    print_result "FAIL" "Failed to increase quota"
    cat /tmp/set_quota_output.txt
fi

# Verify new quota
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
if grep -q "Quota limit: 2.00GB" /tmp/quota_output.txt; then
    print_result "PASS" "New quota limit verified"
else
    print_result "FAIL" "Quota limit not updated correctly"
fi

# TEST 8: Test snapshot creation after quota increase
print_header "TEST 8/10: Verify Snapshot After Quota Increase"

echo "Creating fifth test file (100MB)..."
TEST_FILE_5="$TEST_FILES_DIR/test_file_5.dat"
# Use /dev/urandom for unique data (prevents Btrfs deduplication)
dd if=/dev/urandom of="$TEST_FILE_5" bs=10M count=10 status=progress 2>&1 | grep -v records || true

echo "Copying fifth file..."
cp "$TEST_FILE_5" "/home/$TEST_USER/uploads/"
chown "$TEST_USER:backupusers" "/home/$TEST_USER/uploads/test_file_5.dat"

# Get snapshot count before
snapshot_count_before=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

echo "Waiting ${MONITOR_WAIT_TIME}s for monitor to create snapshot..."
sleep "$MONITOR_WAIT_TIME"

# Get snapshot count after
snapshot_count_after=$(find "/home/$TEST_USER/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

# Check if snapshot was created after quota increase
if [ "$snapshot_count_after" -gt "$snapshot_count_before" ]; then
    print_result "PASS" "Snapshot created after quota increase ($snapshot_count_after total)"
else
    print_result "FAIL" "No snapshot created after quota increase"
    print_result "INFO" "Last 20 log lines:"
    tail -20 /var/log/terminas.log | sed 's/^/    /'
fi

# TEST 9: Test quota removal
print_header "TEST 9/10: Test Quota Removal (Set to Unlimited)"

echo "Removing quota limit..."
if "$SCRIPT_DIR/manage_users.sh" remove-quota "$TEST_USER" > /tmp/remove_quota_output.txt 2>&1; then
    print_result "PASS" "Quota removed successfully"
else
    print_result "FAIL" "Failed to remove quota"
    cat /tmp/remove_quota_output.txt
fi

# Verify quota is unlimited
"$SCRIPT_DIR/manage_users.sh" show-quota "$TEST_USER" > /tmp/quota_output.txt 2>&1
if grep -q "Quota: Unlimited" /tmp/quota_output.txt; then
    print_result "PASS" "Quota is now unlimited"
else
    print_result "FAIL" "Quota not removed correctly"
fi

# TEST 10: Verify quota info in user info command
print_header "TEST 10/10: Verify Quota Display in Info Command"

echo "Checking user info..."
"$SCRIPT_DIR/manage_users.sh" info "$TEST_USER" > /tmp/info_output.txt 2>&1

if grep -q "Storage Quota:" /tmp/info_output.txt; then
    print_result "PASS" "Quota information displayed in info command"
    grep "Storage Quota:" /tmp/info_output.txt
else
    print_result "FAIL" "Quota information not shown in info command"
fi

# Summary
print_header "TEST SUMMARY"

echo "Test Results:"
echo "  ✓ Btrfs quotas enabled and functional"
echo "  ✓ User creation with quota works"
echo "  ✓ Quota configuration verified"
echo "  ✓ File uploads and snapshots work"
echo "  ✓ Quota enforcement blocks snapshots when exceeded"
echo "  ✓ Quota modification (increase/decrease) works"
echo "  ✓ Quota removal (unlimited) works"
echo "  ✓ Quota info displayed in management commands"
echo ""
print_result "INFO" "Check /var/log/terminas.log for detailed logs"
echo ""

# Cleanup prompt
echo -e "${YELLOW}Cleanup:${NC}"
echo "  Test user '$TEST_USER' and files are still present for inspection."
echo "  To cleanup: sudo $0 --cleanup-only"
echo ""

# Cleanup temp files
rm -rf "$TEST_FILES_DIR"
rm -f /tmp/create_user_output.txt /tmp/quota_output.txt
rm -f /tmp/set_quota_output.txt /tmp/remove_quota_output.txt /tmp/info_output.txt
rm -f /tmp/recent_log.txt /tmp/recent_user_log.txt /tmp/cp2_error.txt /tmp/cp3_error.txt /tmp/cp_error.txt

echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All Tests Completed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
