#!/bin/bash

# test_quota_fast.sh - Fast quota enforcement test without waiting for snapshots
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details

set -euo pipefail

# Configuration
TEST_USER="terminas_quota_fast"
TEST_DIR_BASE="/var/tmp/terminas_quota_fast"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
CREATE_USER="$SCRIPT_DIR/create_user.sh"
DELETE_USER="$SCRIPT_DIR/delete_user.sh"
MANAGE_USERS="$SCRIPT_DIR/manage_users.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TEST_FAILED=false

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_result() {
    local result="$1"
    local message="$2"
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS:${NC} $message"
    else
        echo -e "${RED}✗ FAIL:${NC} $message"
        TEST_FAILED=true
    fi
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}" >&2
        exit 1
    fi
}

cleanup_user() {
    if id "$TEST_USER" &>/dev/null; then
        "$DELETE_USER" --force "$TEST_USER" >/dev/null 2>&1 || true
    fi
}

cleanup_uploads() {
    rm -f "/home/$TEST_USER/uploads"/* 2>/dev/null || true
}

make_data_file() {
    local path="$1"
    local size_mb="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/urandom of="$path" bs=1M count="$size_mb" status=none
}

run_copy_expect_success() {
    local src="$1"
    local dest="$2"
    if cp --reflink=never "$src" "$dest" 2>/tmp/cp_error.txt; then
        return 0
    else
        cat /tmp/cp_error.txt >&2 || true
        return 1
    fi
}

run_copy_expect_fail() {
    local src="$1"
    local dest="$2"
    if cp --reflink=never "$src" "$dest" 2>/tmp/cp_error.txt; then
        cat /tmp/cp_error.txt >&2 || true
        return 1
    else
        return 0
    fi
}

main() {
    require_root
    mkdir -p "$TEST_DIR_BASE"
    cleanup_user

    print_header "Create user with 10MB quota"
    if "$CREATE_USER" "$TEST_USER" --quota 10MB >/tmp/create_user_fast.txt 2>&1; then
        print_result "PASS" "User created with 10MB quota"
    else
        cat /tmp/create_user_fast.txt
        print_result "FAIL" "Failed to create test user"
        exit 1
    fi

    # Test 1: 5MB copy should succeed
    print_header "Test 1: copy 5MB (expect success)"
    FILE1="$TEST_DIR_BASE/file1_5mb.dat"
    make_data_file "$FILE1" 5
    if run_copy_expect_success "$FILE1" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "5MB copy succeeded"
    else
        print_result "FAIL" "5MB copy failed"
    fi

    # Test 2: 2MB copy should succeed (total ~7MB)
    print_header "Test 2: copy 2MB (expect success)"
    FILE2="$TEST_DIR_BASE/file2_2mb.dat"
    make_data_file "$FILE2" 2
    if run_copy_expect_success "$FILE2" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "2MB copy succeeded"
    else
        print_result "FAIL" "2MB copy failed"
    fi

    # Test 3: 5MB copy should fail due to 10MB quota
    print_header "Test 3: copy 5MB (expect fail)"
    FILE3="$TEST_DIR_BASE/file3_5mb.dat"
    make_data_file "$FILE3" 5
    if run_copy_expect_fail "$FILE3" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "Quota enforcement blocked 5MB copy"
    else
        print_result "FAIL" "5MB copy unexpectedly succeeded"
    fi

    # Cleanup uploads before increasing quota
    cleanup_uploads

    # Test 4: Increase quota to 1GB
    print_header "Test 4: increase quota to 1GB"
    if "$MANAGE_USERS" set-quota "$TEST_USER" 1 >/tmp/set_quota_fast.txt 2>&1; then
        print_result "PASS" "Quota updated to 1GB"
    else
        cat /tmp/set_quota_fast.txt
        print_result "FAIL" "Failed to update quota"
    fi

    # Test 5: 500MB copy should succeed
    print_header "Test 5: copy 500MB (expect success)"
    FILE5="$TEST_DIR_BASE/file5_500mb.dat"
    make_data_file "$FILE5" 500
    if run_copy_expect_success "$FILE5" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "500MB copy succeeded"
    else
        print_result "FAIL" "500MB copy failed"
    fi

    # Test 6: 600MB copy should fail (total would exceed 1GB)
    print_header "Test 6: copy 600MB (expect fail)"
    FILE6="$TEST_DIR_BASE/file6_600mb.dat"
    make_data_file "$FILE6" 600
    if run_copy_expect_fail "$FILE6" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "Quota enforcement blocked 600MB copy"
    else
        print_result "FAIL" "600MB copy unexpectedly succeeded"
    fi

    # Test 7: remove quota and retry 600MB copy (should succeed)
    print_header "Test 7: remove quota then copy 600MB (expect success)"
    if "$MANAGE_USERS" remove-quota "$TEST_USER" >/tmp/remove_quota_fast.txt 2>&1; then
        print_result "PASS" "Quota removed"
    else
        cat /tmp/remove_quota_fast.txt
        print_result "FAIL" "Failed to remove quota"
    fi

    if run_copy_expect_success "$FILE6" "/home/$TEST_USER/uploads/"; then
        print_result "PASS" "600MB copy succeeded after removing quota"
    else
        print_result "FAIL" "600MB copy failed after removing quota"
    fi

    # Cleanup
    cleanup_uploads
    rm -f "$FILE1" "$FILE2" "$FILE3" "$FILE5" "$FILE6" 2>/dev/null || true
    cleanup_user

    echo ""
    if [ "$TEST_FAILED" = false ]; then
        echo -e "${GREEN}All tests passed.${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
