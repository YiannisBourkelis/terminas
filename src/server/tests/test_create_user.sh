#!/bin/bash

# test_create_user.sh - Test script for user creation and password change functionality
# Tests: User creation, SFTP/Samba authentication, password change, re-authentication
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

set -e

# Test configuration
TEST_USER="terminas_test_create_user"
TEST_FILE_SIZE_MB=10  # Small file for upload test
TEST_FILES_DIR="/var/tmp/terminas_test_create_user"
SFTP_PORT=22
SAMBA_SHARE_NAME="${TEST_USER}-backup"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory (tests folder) and parent directory (server scripts)
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Variables to store passwords
INITIAL_PASSWORD=""
NEW_PASSWORD=""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Parse command line arguments
CLEANUP_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        --cleanup-only|--cleanup|--clenup-only|--clenup)
            CLEANUP_ONLY=true
            shift
            ;;
        *)
            echo -e "${RED}ERROR: Unknown argument: $1${NC}"
            echo "Usage: $0 [--cleanup-only]"
            exit 1
            ;;
    esac
done

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

# Function to cleanup test user and files
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
    
    # Cleanup test files
    if [ -d "$TEST_FILES_DIR" ]; then
        rm -rf "$TEST_FILES_DIR"
        print_result "INFO" "Test files directory removed"
    fi
    
    print_result "INFO" "Cleanup complete"
}

# Function to check if Samba is installed
check_samba_installed() {
    if ! command -v smbpasswd &>/dev/null; then
        return 1
    fi
    
    if ! systemctl is-active --quiet smbd 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# Function to test SFTP authentication
test_sftp_auth() {
    local username="$1"
    local password="$2"
    local description="$3"
    
    echo "Testing SFTP authentication: $description"
    
    # Create test file
    mkdir -p "$TEST_FILES_DIR"
    local test_file="$TEST_FILES_DIR/test_sftp_$RANDOM.txt"
    echo "Test content at $(date)" > "$test_file"
    
    # Try SFTP upload using sshpass (non-interactive)
    if command -v sshpass &>/dev/null; then
        # Use sshpass for automated authentication
        if sshpass -p "$password" sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -P "$SFTP_PORT" "$username@localhost" <<EOF 2>/dev/null
cd uploads
put "$test_file"
bye
EOF
        then
            print_result "PASS" "SFTP authentication successful ($description)"
            rm -f "$test_file"
            return 0
        else
            print_result "FAIL" "SFTP authentication failed ($description)"
            rm -f "$test_file"
            return 1
        fi
    else
        # Fallback: Use lftp if available
        if command -v lftp &>/dev/null; then
            if lftp -u "$username,$password" sftp://localhost:$SFTP_PORT <<EOF 2>/dev/null
cd uploads
put "$test_file"
bye
EOF
            then
                print_result "PASS" "SFTP authentication successful via lftp ($description)"
                rm -f "$test_file"
                return 0
            else
                print_result "FAIL" "SFTP authentication failed via lftp ($description)"
                rm -f "$test_file"
                return 1
            fi
        else
            print_result "INFO" "Skipping SFTP test - neither sshpass nor lftp available"
            print_result "INFO" "Install sshpass: apt install sshpass"
            rm -f "$test_file"
            return 0  # Don't fail test if tools not available
        fi
    fi
}

# Function to test Samba authentication
test_samba_auth() {
    local username="$1"
    local password="$2"
    local description="$3"
    
    echo "Testing Samba authentication: $description"
    
    # Check if smbclient is available
    if ! command -v smbclient &>/dev/null; then
        print_result "INFO" "Skipping Samba test - smbclient not available"
        print_result "INFO" "Install smbclient: apt install smbclient"
        return 0  # Don't fail test if tool not available
    fi
    
    # Try to list share contents using smbclient
    if smbclient "//localhost/$SAMBA_SHARE_NAME" -U "$username%$password" -c "ls" &>/dev/null; then
        print_result "PASS" "Samba authentication successful ($description)"
        return 0
    else
        print_result "FAIL" "Samba authentication failed ($description)"
        return 1
    fi
}

# Cleanup if requested
if [ "$CLEANUP_ONLY" = true ]; then
    cleanup_test_user
    exit 0
fi

# Main test execution
print_header "termiNAS User Creation and Password Change Test"

echo "This test will:"
echo "  1. Create a test user with Samba enabled"
echo "  2. Test SFTP and Samba authentication with initial password"
echo "  3. Change the password using manage_users.sh change-password"
echo "  4. Test SFTP and Samba authentication with new password"
echo "  5. Verify old password no longer works"
echo ""

# Check dependencies
echo "Checking dependencies..."
missing_deps=()

if ! command -v sshpass &>/dev/null && ! command -v lftp &>/dev/null; then
    missing_deps+=("sshpass or lftp")
fi

if ! command -v smbclient &>/dev/null; then
    missing_deps+=("smbclient")
fi

if ! command -v expect &>/dev/null; then
    missing_deps+=("expect")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${RED}ERROR: Missing required dependencies:${NC}"
    for dep in "${missing_deps[@]}"; do
        echo "  - $dep"
    done
    echo ""
    echo "Install with:"
    echo "  apt install sshpass smbclient expect"
    echo ""
    echo "Or re-run setup.sh to install all dependencies"
    exit 1
fi

# Check if Samba is available
SAMBA_AVAILABLE=false
if check_samba_installed; then
    SAMBA_AVAILABLE=true
    print_result "INFO" "Samba is installed and running"
else
    print_result "INFO" "Samba is not available - only SFTP will be tested"
fi

# Step 1: Create test user
print_header "Step 1: Create test user with Samba"

echo "Creating user: $TEST_USER"
if [ "$SAMBA_AVAILABLE" = true ]; then
    # Create user with Samba support
    output=$("$SCRIPT_DIR/create_user.sh" "$TEST_USER" --samba 2>&1)
else
    # Create user without Samba
    output=$("$SCRIPT_DIR/create_user.sh" "$TEST_USER" 2>&1)
fi

# Extract password from output
INITIAL_PASSWORD=$(echo "$output" | grep -oP 'Generated secure password: \K.*' || echo "$output" | grep -oP 'password: \K\S+')

if [ -z "$INITIAL_PASSWORD" ]; then
    print_result "FAIL" "Could not extract generated password from create_user.sh output"
    echo "Output was:"
    echo "$output"
    cleanup_test_user
    exit 1
fi

print_result "PASS" "User created successfully"
print_result "INFO" "Initial password extracted (${#INITIAL_PASSWORD} characters)"

# Step 2: Test authentication with initial password
print_header "Step 2: Test authentication with initial password"

SFTP_TEST1_RESULT=0
SAMBA_TEST1_RESULT=0

test_sftp_auth "$TEST_USER" "$INITIAL_PASSWORD" "initial password" || SFTP_TEST1_RESULT=1

if [ "$SAMBA_AVAILABLE" = true ]; then
    test_samba_auth "$TEST_USER" "$INITIAL_PASSWORD" "initial password" || SAMBA_TEST1_RESULT=1
fi

if [ $SFTP_TEST1_RESULT -ne 0 ] || ([ "$SAMBA_AVAILABLE" = true ] && [ $SAMBA_TEST1_RESULT -ne 0 ]); then
    print_result "FAIL" "Initial authentication tests failed"
    cleanup_test_user
    exit 1
fi

# Step 3: Change password
print_header "Step 3: Change password using manage_users.sh"

# Generate new password that meets requirements
NEW_PASSWORD="NewSecurePassword123456789ABCDEFGHIJKLMNOP"  # 43 characters, has lowercase, uppercase, numbers

echo "Changing password for user: $TEST_USER"
echo "New password: $NEW_PASSWORD"

# Use expect or heredoc to automate password change
if command -v expect &>/dev/null; then
    # Use expect for interactive password prompts
    expect <<EOF 2>/dev/null
spawn "$SCRIPT_DIR/manage_users.sh" change-password "$TEST_USER"
expect "Enter new password*"
send "$NEW_PASSWORD\r"
expect "Confirm new password*"
send "$NEW_PASSWORD\r"
expect eof
EOF
    CHANGE_RESULT=$?
else
    # Fallback: Try to pipe passwords (may not work with all systems)
    print_result "INFO" "expect not available, using password piping (may require manual intervention)"
    echo -e "$NEW_PASSWORD\n$NEW_PASSWORD" | "$SCRIPT_DIR/manage_users.sh" change-password "$TEST_USER" 2>&1 || true
    CHANGE_RESULT=$?
fi

if [ $CHANGE_RESULT -eq 0 ]; then
    print_result "PASS" "Password change command completed"
else
    print_result "FAIL" "Password change command failed with exit code $CHANGE_RESULT"
    cleanup_test_user
    exit 1
fi

# Small delay to ensure password propagation
sleep 2

# Step 4: Test authentication with new password
print_header "Step 4: Test authentication with new password"

SFTP_TEST2_RESULT=0
SAMBA_TEST2_RESULT=0

test_sftp_auth "$TEST_USER" "$NEW_PASSWORD" "new password" || SFTP_TEST2_RESULT=1

if [ "$SAMBA_AVAILABLE" = true ]; then
    test_samba_auth "$TEST_USER" "$NEW_PASSWORD" "new password" || SAMBA_TEST2_RESULT=1
fi

if [ $SFTP_TEST2_RESULT -ne 0 ] || ([ "$SAMBA_AVAILABLE" = true ] && [ $SAMBA_TEST2_RESULT -ne 0 ]); then
    print_result "FAIL" "New password authentication tests failed"
    cleanup_test_user
    exit 1
fi

# Step 5: Verify old password no longer works
print_header "Step 5: Verify old password is rejected"

echo "Testing SFTP with old password (should fail)..."
if command -v sshpass &>/dev/null; then
    if sshpass -p "$INITIAL_PASSWORD" sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$SFTP_PORT" "$TEST_USER@localhost" <<EOF 2>/dev/null
bye
EOF
    then
        print_result "FAIL" "Old password still works for SFTP (should have been rejected)"
        cleanup_test_user
        exit 1
    else
        print_result "PASS" "Old password correctly rejected for SFTP"
    fi
else
    print_result "INFO" "Skipping old password rejection test - sshpass not available"
fi

if [ "$SAMBA_AVAILABLE" = true ]; then
    echo "Testing Samba with old password (should fail)..."
    if command -v smbclient &>/dev/null; then
        if smbclient "//localhost/$SAMBA_SHARE_NAME" -U "$TEST_USER%$INITIAL_PASSWORD" -c "ls" &>/dev/null 2>&1; then
            print_result "FAIL" "Old password still works for Samba (should have been rejected)"
            cleanup_test_user
            exit 1
        else
            print_result "PASS" "Old password correctly rejected for Samba"
        fi
    fi
fi

# Final summary
print_header "Test Summary"

print_result "PASS" "All password change tests completed successfully!"
echo ""
echo "Test results:"
echo "  ✓ User creation with password generation"
echo "  ✓ SFTP authentication with initial password"
if [ "$SAMBA_AVAILABLE" = true ]; then
    echo "  ✓ Samba authentication with initial password"
fi
echo "  ✓ Password change command execution"
echo "  ✓ SFTP authentication with new password"
if [ "$SAMBA_AVAILABLE" = true ]; then
    echo "  ✓ Samba authentication with new password"
fi
echo "  ✓ Old password rejection verification"
echo ""

# Cleanup
print_result "INFO" "Cleaning up test user and files..."
cleanup_test_user

echo ""
print_result "PASS" "User creation and password change test completed successfully!"
