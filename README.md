# iCloud Backup

A macOS shell script that backs up iCloud Drive to an external drive, folder by folder, evicting each folder after a successful copy to keep local disk usage low. Optionally encrypts the backup using a VeraCrypt volume.

## Features

- **Incremental backups** — only copies files that have changed since the last run (`rsync -u`)
- **Disk-aware** — downloads one folder at a time from iCloud, copies it, then evicts it from local storage so your Mac SSD doesn't fill up
- **Smart re-runs** — skips items already up-to-date on the destination without re-downloading from iCloud
- **VeraCrypt encryption** — optionally backs up into an encrypted container that is automatically dismounted on exit (including crashes and Ctrl+C)
- **Mirror mode** — optionally deletes files from the backup that no longer exist in iCloud
- **Exclude patterns** — skip specific folders or file patterns
- **Checksum verification** — optional post-copy integrity check
- **Progress tracking** — shows `[3/15]` style progress during long runs
- **Per-item space checks** — verifies sufficient disk space before each copy to avoid mid-write failures
- **Quiet mode** — `--quiet` suppresses terminal output for cron/scheduled use (logs to file only)
- **External config file** — override defaults via `~/.icloud_backup.conf` or environment variables, no need to edit the script
- **Symlink-aware** — follows directory symlinks (Documents, Downloads) that macOS creates when "Desktop & Documents Folders" is enabled in iCloud
- **Logging** — timestamped logs in `~/Library/Logs/icloud-backup/`, auto-cleaned to the 10 most recent

## Requirements

- macOS (uses `brctl` for iCloud Drive management)
- `rsync` (pre-installed on macOS)
- iCloud Drive enabled and signed in
- [VeraCrypt](https://veracrypt.io) (only if using `--veracrypt`)

## Quick Start

1. Clone or download the script
2. Create a config file with your backup destination:
   ```bash
   echo 'BACKUP_DIR="/Volumes/MyExternalDrive/icloud-backup"' > ~/.icloud_backup.conf
   ```
3. Make executable and run:
   ```bash
   chmod +x icloud_backup.sh
   ./icloud_backup.sh
   ```

## Usage

```
./icloud_backup.sh [--dry-run] [--veracrypt] [--mirror] [--verify] [--quiet] [--exclude=PATTERN ...]
```

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview what would happen without making any changes |
| `--veracrypt` | Mount a VeraCrypt encrypted volume as the backup destination |
| `--mirror` | Enable true mirroring — files deleted from iCloud are also deleted from the backup (adds `--delete` to rsync) |
| `--verify` | Run a checksum verification pass after each folder is copied |
| `--quiet` | Suppress all terminal output; log to file only. Useful for cron jobs |
| `--exclude=PATTERN` | Skip folders or files matching the pattern. Can be specified multiple times |

### Examples

```bash
# Basic incremental backup to an external drive
./icloud_backup.sh

# Preview what would be backed up (no changes made)
./icloud_backup.sh --dry-run

# Encrypted backup into a VeraCrypt volume
./icloud_backup.sh --veracrypt

# True mirror with verification, excluding large folders
./icloud_backup.sh --mirror --verify --exclude=Photos --exclude='*.tmp'

# Preview an encrypted mirror backup
./icloud_backup.sh --veracrypt --mirror --dry-run

# Silent backup for cron — output goes to log file only
./icloud_backup.sh --quiet

# Override backup destination via environment variable
BACKUP_DIR=/Volumes/USB-Drive ./icloud_backup.sh
```

## Configuration

Configuration can be set in three ways (highest precedence first):

1. **Environment variables** at invocation — `BACKUP_DIR=/my/path ./icloud_backup.sh`
2. **Config file** at `~/.icloud_backup.conf` (or set `ICLOUD_BACKUP_CONF` to use a different path)
3. **Hardcoded defaults** in the script

The config file is a plain shell file that gets sourced. Example `~/.icloud_backup.conf`:

```bash
BACKUP_DIR="/Volumes/MyUSBDrive/icloud-backup"
VERACRYPT_VOLUME="/Volumes/MyUSBDrive/encrypted.vc"
VERACRYPT_MOUNT="/Volumes/iCloudBackup"
```

### Available variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ICLOUD_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs` | Path to your iCloud Drive |
| `BACKUP_DIR` | `/Volumes/iCloudBackup` | Backup destination (plain folder or VeraCrypt mount point) |
| `VERACRYPT_VOLUME` | `/Volumes/MyExternalDrive/encrypted.vc` | Path to your `.vc` file on the external drive |
| `VERACRYPT_MOUNT` | `/Volumes/iCloudBackup` | Where VeraCrypt will mount the volume |
| `VERACRYPT_CLI` | `/Applications/VeraCrypt.app/Contents/MacOS/VeraCrypt` | Path to the VeraCrypt CLI binary |
| `ICLOUD_BACKUP_CONF` | `~/.icloud_backup.conf` | Path to the config file itself |

## VeraCrypt Setup

If you want encrypted backups, create a VeraCrypt volume once before your first run:

1. Download and install [VeraCrypt](https://veracrypt.io)
2. Open VeraCrypt and click **Create Volume**
3. Choose **Create an encrypted file container**
4. Choose **Standard VeraCrypt volume**
5. Click **Select File**, navigate to your external drive (e.g. `/Volumes/MyExternalDrive`) and save as `encrypted.vc`
6. Choose encryption: **AES + SHA-512** (strong defaults)
7. Set the volume size to match your iCloud data (leave some headroom)
8. Set a strong password and store it in a password manager
9. Format the volume as **exFAT** (cross-platform) or **HFS+** (Mac only)
10. Set `VERACRYPT_VOLUME` and `VERACRYPT_MOUNT` in `~/.icloud_backup.conf` to match your paths

The script will prompt for the password at runtime. It is never logged or stored.

## How It Works

For each top-level item in iCloud Drive, the script:

1. **Checks** if the item is excluded or already up-to-date on the destination
2. **Downloads** the item from iCloud using `brctl download` (including nested files)
3. **Waits** for all `.icloud` stub files to resolve (up to 5 minutes per item)
4. **Checks** that the destination has enough free space for the item
5. **Copies** the item to the backup destination via `rsync`
6. **Verifies** checksums if `--verify` is enabled
7. **Evicts** the local copy via `brctl evict` (recursively) to free disk space

If VeraCrypt is enabled, the encrypted volume is mounted before the backup and automatically dismounted on exit via a shell trap — even on errors or Ctrl+C.

### Symlinked folders

When "Desktop & Documents Folders" is enabled in iCloud settings, macOS places symlinks for Documents and Downloads inside iCloud Drive rather than real directories. The script uses rsync's `--copy-dirlinks` flag to follow these symlinks and back up their full contents as real directories.

## Logs

Logs are stored in `~/Library/Logs/icloud-backup/` with timestamped filenames. The 10 most recent logs are kept; older ones are automatically deleted.

## License

MIT
