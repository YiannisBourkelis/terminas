# termiNAS Test Scripts

This directory contains test scripts for validating termiNAS functionality.

## Available Tests

### `test_create_user.sh` - User Creation and Password Change Tests

Comprehensive test suite for user creation and password change functionality including:
- User creation with auto-generated password
- SFTP authentication with initial password
- Samba authentication with initial password (if Samba enabled)
- Password change via `manage_users.sh change-password`
- SFTP authentication with new password
- Samba authentication with new password (if Samba enabled)
- Verification that old password is rejected

**Usage:**
```bash
# Run all user creation and password change tests
sudo ./test_create_user.sh

# Cleanup test user and files
sudo ./test_create_user.sh --cleanup-only
```

**Test Configuration:**
- Test user: `terminas_test_create_user`
- Initial password: Auto-generated 64-character secure password
- New password: 43-character password meeting all requirements
- Tests both SFTP and Samba (if available)

**What it tests:**
1. User creation with auto-generated password
2. Password extraction from create_user.sh output
3. SFTP authentication with initial password
4. Samba authentication with initial password (if Samba installed)
5. Password change command execution
6. SFTP authentication with new password
7. Samba authentication with new password (if Samba installed)
8. Old password rejection for both SFTP and Samba

**Dependencies:**
- **Required**: openssh-server (SFTP)
- **Optional**: sshpass or lftp (for automated SFTP tests)
- **Optional**: samba, smbclient (for Samba tests)
- **Optional**: expect (for automated password prompts)

**Expected Output:**
- ✓ PASS: Test succeeded
- ✗ FAIL: Test failed (check logs)
- ℹ INFO: Informational message

**Notes:**
- Test will skip SFTP tests if neither sshpass nor lftp is available
- Test will skip Samba tests if Samba is not installed or running
- Test automatically cleans up after completion
- If expect is not available, password change may require manual intervention

### `test_quota.sh` - Quota Functionality Tests

Comprehensive test suite for Btrfs quota functionality including:
- Quota configuration verification
- User creation with quota limits
- File uploads within quota
- Quota enforcement (blocking when exceeded)
- Quota modification (increase/decrease)
- Quota removal (unlimited)
- Integration with management commands

**Usage:**
```bash
# Run all quota tests
sudo ./test_quota.sh

# Cleanup test user and files
sudo ./test_quota.sh --cleanup-only
```

**Test Configuration:**
- Test user: `terminas_test_quota`
- Quota limit: 1GB (expandable during tests)
- Test file size: 300MB each
- Monitor wait time: 70s (for snapshot creation)

**What it tests:**
1. Btrfs quotas are enabled on `/home`
2. User creation with `--quota` parameter
3. Quota configuration via qgroups
4. File uploads and automatic snapshots
5. Quota enforcement blocks snapshots when exceeded
6. Quota warnings at 90% threshold
7. Quota modification commands work correctly
8. Quota removal sets to unlimited
9. Quota info displayed in `manage_users.sh` commands
10. Log entries for quota events

**Expected Output:**
- ✓ PASS: Test succeeded
- ✗ FAIL: Test failed (check logs)
- ℹ INFO: Informational message

**Notes:**
- Test user remains after completion for inspection
- Check `/var/log/terminas.log` for detailed logs
- Run cleanup before re-running tests

## Adding New Tests

When adding new test scripts:

1. **Name:** `test_<feature>.sh` (e.g., `test_samba.sh`, `test_retention.sh`)
2. **Make executable:** `chmod +x test_<feature>.sh`
3. **Use colors:** RED, GREEN, YELLOW, BLUE for output
4. **Include cleanup:** `--cleanup-only` option
5. **Document here:** Add entry to this README

### Test Script Template

```bash
#!/bin/bash
# test_<feature>.sh - Test script for <feature> functionality
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get directories
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Test configuration
TEST_USER="terminas_test_<feature>"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Must run as root${NC}"
    exit 1
fi

# Cleanup function
cleanup() {
    if id "$TEST_USER" &>/dev/null; then
        "$SCRIPT_DIR/delete_user.sh" "$TEST_USER" || true
    fi
}

# Handle --cleanup-only
if [ "${1:-}" = "--cleanup-only" ]; then
    cleanup
    exit 0
fi

# Run tests
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
    elif [ "$result" = "FAIL" ]; then
        echo -e "${RED}✗ FAIL:${NC} $message"
    elif [ "$result" = "INFO" ]; then
        echo -e "${YELLOW}ℹ INFO:${NC} $message"
    fi
}

# Test implementation here...
```

## Running All Tests

To run all tests in sequence:

```bash
# Run each test script
for test in test_*.sh; do
    echo "Running $test..."
    sudo ./"$test" || echo "Test failed: $test"
    echo ""
done

# Cleanup all tests
for test in test_*.sh; do
    sudo ./"$test" --cleanup-only
done
```

## CI/CD Integration

These tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions workflow
- name: Run termiNAS tests
  run: |
    cd src/server/tests
    sudo ./test_quota.sh
    sudo ./test_quota.sh --cleanup-only
```

## Troubleshooting

**Test fails immediately:**
- Check if running as root: `sudo ./test_quota.sh`
- Verify termiNAS is properly installed: `./setup.sh`
- Check Btrfs is mounted on `/home`: `df -T /home`

**Monitor tests fail:**
- Verify monitor service is running: `systemctl status terminas-monitor.service`
- Check monitor logs: `tail -f /var/log/terminas.log`
- Increase `MONITOR_WAIT_TIME` in test script

**Cleanup fails:**
- Manually delete test user: `./delete_user.sh terminas_test_quota`
- Remove runtime files: `rm -f /var/run/terminas/*test*`

## Contributing

When contributing new tests:
- Follow the existing test structure
- Include comprehensive error checking
- Provide clear PASS/FAIL indicators
- Document expected behavior
- Clean up all test artifacts
