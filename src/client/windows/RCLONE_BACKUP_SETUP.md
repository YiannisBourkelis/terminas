# Rclone Backup Setup (Windows)

This guide describes how to use **rclone + SFTP** to back up a local folder to a termiNAS server.

## 1) Download and install rclone

- Download the latest rclone release for your OS from:
  - https://github.com/rclone/rclone
- Extract it and place `rclone.exe` in a **user-protected folder** where no other users have access.
  - Example: `C:\Users\USER_NAME\Apps\rclone\rclone.exe`
  - Make sure NTFS permissions on that folder only allow your user (and Administrators).

## 2) Create a termiNAS user (server-side)

On the termiNAS server, create a backup user using the server script:

- From the repo folder on the server:
  - `sudo ./src/server/create_user.sh <username>`

This will create the SFTP-only user and the expected folder structure.

## 3) Create an rclone remote (Windows)

On the Windows machine, open **Command Prompt** (or PowerShell) and run:

- `rclone.exe config`

Create a new remote (example remote name: `testuser1`) and fill:

- Type: `sftp`
- termiNAS IP address (host): e.g. `185.213.24.187`
- Username: e.g. `testuser1` (or whatever you created)
- Password: enter the password provided by the server

## Notes for older Windows

- **Windows versions prior to Windows 10** should use **rclone v1.63.1**.
- In **rclone v1.63.1**, these log rotation flags **do not exist**:
  - `--log-file-max-size 10M`
  - `--log-file-max-backups 10`
  - `--log-file-max-age 30d`

If you are using v1.63.1, keep logs via `--log-file` only, or use a per-run timestamped log file and rotate with Windows tools (e.g. `forfiles`).

## 4) Test the backup (Windows cmd.exe)

After creating the rclone config, test a one-way sync (local rightarrow server). This keeps folders in sync by **deleting only on the server** when files are removed locally.

Example test command (newer rclone versions):

- `rclone.exe sync "C:\Users\USER_NAME\Downloads\test-user1" testuser1:uploads --log-file "C:\Users\USER_NAME\Downloads\rclone-testuser1.log" --log-level INFO --log-file-max-size 10M --log-file-max-backups 10 --log-file-max-age 30d`

If your server is chrooted and `uploads` isnt found, try `testuser1:/uploads` instead.

## 5) Schedule daily backups (Windows Task Scheduler)

If the test succeeds, create a **Windows Task Scheduler** task to run periodically (e.g. daily).

Recommended Task Scheduler settings:

- **General**
  - Run whether user is logged on or not
  - Run with highest privileges (if needed for reading the source folder)

- **Action** (Start a program)
  - Program/script: full path to `rclone.exe`
    - Example: `C:\Users\USER_NAME\Apps\rclone\rclone.exe`
  - Add arguments (recommended):
    - `sync "C:\Users\USER_NAME\Downloads\test-user1" testuser1:uploads --log-file "C:\Users\USER_NAME\Downloads\rclone-testuser1.log" --log-level INFO --log-file-max-size 10M --log-file-max-backups 10 --log-file-max-age 30d`

If you are on rclone v1.63.1, remove the `--log-file-max-*` flags and rotate logs externally.
