# termiNAS v1.0.0-alpha.4 Release Notes

**Release Date**: March 2, 2026  
**Release Type**: Alpha (Experimental)

## ⚠️ Important Notice

This is an **alpha release** intended for testing purposes only. While functional, termiNAS has not been extensively tested in production environments. Always maintain independent backups of critical data.

## 🚀 What's New in Alpha 4

This release focuses on **unifying backup clients around rclone** for both Linux and Windows platforms, providing a consistent and reliable backup experience across operating systems.

### Major Changes

#### Unified rclone-Based Backup Clients
- **Linux and Windows clients now use rclone** for SFTP backups
- Consistent behavior and configuration across platforms
- Simplified troubleshooting with a single tool to understand

**Linux Client:**
- Removed standalone `upload.sh` script
- Integrated rclone configuration directly into `setup-client.sh`
- Single-script setup experience: just run `setup-client.sh` and follow prompts
- Automatic cron job creation for scheduled backups

**Windows Client:**
- Replaced PowerShell scripts with rclone-based approach
- Comprehensive setup guide in `RCLONE_BACKUP_SETUP.md`
- Task Scheduler integration for automated backups
- Works with older Windows versions using rclone v1.63.1

### Performance Improvements

#### Optimized User Size Calculations
- **Improved `manage_users.sh list` performance** by replacing parallel `btrfs filesystem du` calls with a single qgroup data fetch
- More accurate and consistent size reporting across all user management commands
- Enhanced `get_apparent_size` function for faster file size calculations

### Bug Fixes

#### Year Rollover Handling
- **Fixed timestamp processing in connection cache functions** for accurate handling across year boundaries
- `build_connection_cache` and `build_samba_connection_cache` now correctly process logs spanning multiple years

#### Snapshot Handling
- Added `parse_snapshot_timestamp` function for accurate extraction of creation times from snapshot directory names
- Refactored `get_last_backup_date` to use `get_snapshot_info` for improved consistency

#### Variable Name Handling
- Added notes for handling usernames with dashes in variable names in setup and manage_users scripts

## 📦 Installation

**New Installation:**
```bash
git clone https://github.com/YiannisBourkelis/terminas.git
cd terminas
sudo ./src/server/setup.sh
```

**Upgrade from Previous Versions:**
```bash
cd /path/to/terminas
git pull origin main
# No additional steps needed - scripts are backward compatible
```

**Linux Client Setup (New):**
```bash
# Download and run setup script
curl -O https://raw.githubusercontent.com/YiannisBourkelis/terminas/main/src/client/linux/setup-client.sh
chmod +x setup-client.sh
sudo ./setup-client.sh
```

**Windows Client Setup:**
See `src/client/windows/RCLONE_BACKUP_SETUP.md` for detailed instructions.

## 🐛 Known Issues

- Limited testing on non-Debian systems
- Samba/SMB support is optional and requires manual testing
- Time Machine support may have edge cases

## 📚 Documentation

- **README.md**: Complete setup and usage guide
- **CHANGELOG.md**: Detailed change history
- **CONTRIBUTING.md**: Guidelines for contributors
- **docs/LINUX_CLIENT_ARCHITECTURE.md**: Linux client technical reference
- **src/client/windows/RCLONE_BACKUP_SETUP.md**: Windows rclone setup guide

## 🔗 Resources

- **Repository**: https://github.com/YiannisBourkelis/terminas
- **Issues**: https://github.com/YiannisBourkelis/terminas/issues
- **License**: MIT License

## 🙏 Feedback

As an alpha release, your feedback is crucial! Please report:
- Bugs and issues on GitHub
- Performance problems
- Feature requests
- Documentation improvements

**Testing Checklist:**
- ✅ Linux client setup with rclone works correctly
- ✅ Windows client rclone setup following documentation
- ✅ `manage_users.sh list` performance improved
- ✅ Year rollover handling in connection logs
- ⏳ All other functionality remains unchanged and stable

## 📝 Full Changelog

See [CHANGELOG.md](CHANGELOG.md) for complete details.
