# termiNAS Quota Architecture

This document explains how per-user storage quotas are configured, enabled, modified, monitored, and enforced across termiNAS. It applies to Btrfs-based deployments using the default simple quota (squota) mode.

## Configuration Lifecycle

- **Setup (`setup.sh`)**
  - Enables Btrfs simple quotas on `/home` (`btrfs quota enable --simple /home`).
  - Generates `/var/terminas/scripts/terminas-monitor.sh` (real-time monitor) and `/var/terminas/scripts/terminas-cleanup.sh` (retention + recheck) with built-in quota helpers.
  - Installs `terminas-monitor.service` to run the monitor.
  - Leaves the default quota for new users at `DEFAULT_QUOTA_GB` (0 = unlimited) in `/etc/terminas-retention.conf`.

- **User Creation (`create_user.sh`)**
  - Creates uploads as a Btrfs subvolume: `/home/<user>/uploads`.
  - Reads requested quota (`--quota <GB|MB>`); falls back to `DEFAULT_QUOTA_GB` if unspecified.
  - Parses quota via shared helper; hard-fails on invalid input before creating the user.
  - Writes metadata under the user’s home:
    - `.terminas-qgroup`: the uploads qgroup ID (`0/<subvol_id>`).
    - `.terminas-quota-limit`: stored quota value (with unit if MB specified; otherwise GB number).
  - Applies the hard quota on the uploads qgroup (`btrfs qgroup limit <bytes> 0/<subvol_id> /home`).

- **User Management (`manage_users.sh`)**
  - `set-quota <user> <GB|MB>`: validates input, sets qgroup limit, updates `.terminas-quota-limit`, clears `.terminas-quota-exceeded`.
  - `remove-quota <user>`: removes the limit (sets unlimited), updates `.terminas-quota-limit` to 0, clears flag.
  - `show-quota <user>`: reports usage, limits, and blocked status.

- **User Deletion (`delete_user.sh`)**
  - Deletes the user, uploads subvolume, snapshots, and associated quota metadata files (`.terminas-qgroup`, `.terminas-quota-limit`, `.terminas-quota-exceeded`).

## Enabling, Disabling, Modifying Quotas

- **Enable/Set**: During creation with `--quota`, or later via `manage_users.sh set-quota`. Applies a hard qgroup limit and records `.terminas-quota-limit`.
- **Disable**: `manage_users.sh remove-quota` (sets unlimited and clears flag). Creation with quota 0 also means unlimited.
- **Modify**: Re-run `set-quota` with a new value; overwrites the qgroup limit and updates `.terminas-quota-limit`.

## Enforcement Model (Hybrid)

- **Hard enforcement (uploads subvolume)**
  - A level-0 qgroup on `/home/<user>/uploads` enforces the configured byte limit immediately on writes.
  - This prevents new data from being written once the uploads subvolume hits its qgroup limit.

- **Hybrid total check (uploads + snapshots)**
  - After each snapshot, the monitor sums exclusive usage of uploads plus all snapshots using qgroup data.
  - If total usage exceeds the configured limit, the monitor:
    - Sets the uploads qgroup limit to 1 byte (blocks further uploads).
    - Writes `/home/<user>/.terminas-quota-exceeded` with the total usage.
  - When total usage drops below the limit (delete events or cleanup recheck), it restores the normal limit and removes the flag.

- **Flag files and metadata**
  - `.terminas-qgroup`: qgroup ID for uploads (level-0).
  - `.terminas-quota-limit`: configured limit (GB number or MB-suffixed value; 0 = unlimited).
  - `.terminas-quota-exceeded`: presence indicates uploads are blocked due to over-total usage; contains last recorded total bytes.

## Monitoring and Services

- **terminas-monitor.sh** (systemd service `terminas-monitor.service`)
  - Watches `/home` for `close_write` and `delete` under `uploads/`.
  - Debounces activity and creates Btrfs snapshots under `/home/<user>/versions/<timestamp>`.
  - Runs hybrid quota check after each snapshot; blocks/unblocks uploads by adjusting qgroup limits and setting/clearing `.terminas-quota-exceeded`.
  - On delete events, if the user is blocked, it rechecks total usage to auto-unblock when under limit.

- **terminas-cleanup.sh** (cron, daily)
  - Applies retention (GFS or age-based) and removes old snapshots.
  - After cleanup, rechecks blocked users: recalculates total usage; if under limit, restores the uploads qgroup limit and removes `.terminas-quota-exceeded`.

## Exceeding Quota: What Happens

1. If uploads subvolume hits its hard limit: write attempts fail immediately (qgroup limit). User cannot upload more.
2. If total usage (uploads + snapshots) exceeds limit after a snapshot:
   - Monitor sets uploads qgroup limit to 1 byte (blocks uploads) and writes `.terminas-quota-exceeded`.
   - User must delete files from `uploads/` or wait for retention cleanup to free space.
3. When space is freed (delete event or cleanup recheck):
   - Monitor/cleanup recalculates totals; if under limit, restores the configured qgroup limit and removes the flag.

## Quick Reference Commands

- Create user with 50GB quota: `./create_user.sh alice --quota 50`
- Set quota to 10MB: `./manage_users.sh set-quota alice 10MB`
- Remove quota (unlimited): `./manage_users.sh remove-quota alice`
- Show quota: `./manage_users.sh show-quota alice`
- Force cleanup/recheck via retention job: run the daily cleanup or delete files in `uploads/` to trigger monitor recheck.
