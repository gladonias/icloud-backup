#!/usr/bin/env bash
# =============================================================================
# icloud_backup.sh
# Backs up iCloud Drive to an external hard drive, folder by folder,
# evicting each folder after a successful copy to keep Mac disk usage low.
# Optionally wraps the backup in a VeraCrypt encrypted volume.
#
# Usage:
#   ./icloud_backup.sh                          # Plain backup, no encryption
#   ./icloud_backup.sh --dry-run                # Preview only, no changes
#   ./icloud_backup.sh --veracrypt              # Backup into VeraCrypt volume
#   ./icloud_backup.sh --veracrypt --dry-run    # Preview with VeraCrypt paths
#
# =============================================================================
# FIRST-TIME VERACRYPT SETUP (do this once before running with --veracrypt)
# =============================================================================
# 1. Download and install VeraCrypt from https://veracrypt.io
#
# 2. Open VeraCrypt and click "Create Volume"
#
# 3. Choose "Create an encrypted file container"
#
# 4. Choose "Standard VeraCrypt volume"
#
# 5. Click "Select File", navigate to your external drive (e.g.
#    /Volumes/MyExternalDrive) and save the file as: encrypted.vc
#    This creates the file: /Volumes/MyExternalDrive/encrypted.vc
#
# 6. Choose encryption: AES + SHA-512 (strong defaults, fine for backup)
#
# 7. Set the volume size to match your iCloud data size (leave some headroom)
#
# 8. Set a strong password — store it somewhere safe (password manager, etc.)
#    This is the password the script will prompt you for at runtime.
#
# 9. Format the volume as exFAT (cross-platform) or HFS+ (Mac only)
#
# 10. Update VERACRYPT_VOLUME and VERACRYPT_MOUNT below to match your paths.
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration — edit these before running
# -----------------------------------------------------------------------------
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
BACKUP_DIR="/Volumes/iCloudBackup"                        # mount point when using VeraCrypt,
                                                          # or a plain folder path without it
VERACRYPT_VOLUME="/Volumes/MyExternalDrive/encrypted.vc"  # path to your .vc file on the drive
VERACRYPT_MOUNT="/Volumes/iCloudBackup"                   # where VeraCrypt will mount it
VERACRYPT_CLI="/Applications/VeraCrypt.app/Contents/MacOS/VeraCrypt"

# -----------------------------------------------------------------------------
# Parse flags
# -----------------------------------------------------------------------------
DRY_RUN=false
USE_VERACRYPT=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --veracrypt)  USE_VERACRYPT=true ;;
    *)
      echo "Unknown flag: $arg"
      echo "Usage: $0 [--dry-run] [--veracrypt]"
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Log setup
# -----------------------------------------------------------------------------
LOG_FILE="$HOME/icloud_backup_$(date +%Y%m%d_%H%M%S).log"
ERROR_COUNT=0

log()   { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
error() { echo "[$(date '+%H:%M:%S')] ❌ ERROR: $*" | tee -a "$LOG_FILE"; ((ERROR_COUNT++)) || true; }

# -----------------------------------------------------------------------------
# VeraCrypt mount / unmount functions
# -----------------------------------------------------------------------------
VERACRYPT_MOUNTED=false

mount_veracrypt() {
  log "🔐 Mounting VeraCrypt volume: $VERACRYPT_VOLUME"

  if [[ ! -f "$VERACRYPT_VOLUME" ]]; then
    error "VeraCrypt volume file not found: $VERACRYPT_VOLUME"
    error "Please create the volume first — see the setup instructions at the top of this script."
    exit 1
  fi

  if [[ ! -x "$VERACRYPT_CLI" ]]; then
    error "VeraCrypt CLI not found at: $VERACRYPT_CLI"
    error "Please install VeraCrypt from https://veracrypt.io"
    exit 1
  fi

  # Prompt for password securely — never logged or stored anywhere
  echo -n "Enter VeraCrypt password: "
  read -rs VC_PASSWORD
  echo ""

  if ! "$VERACRYPT_CLI" \
      --text \
      --non-interactive \
      --mount "$VERACRYPT_VOLUME" "$VERACRYPT_MOUNT" \
      --password="$VC_PASSWORD" \
      --keyfiles="" \
      --protect-hidden=no 2>>"$LOG_FILE"; then
    # Clear the password from memory before exiting
    unset VC_PASSWORD
    error "Failed to mount VeraCrypt volume. Wrong password, or the volume is already mounted."
    exit 1
  fi

  # Clear the password from memory immediately after use
  unset VC_PASSWORD
  VERACRYPT_MOUNTED=true
  log "✅ VeraCrypt volume mounted at: $VERACRYPT_MOUNT"
}

unmount_veracrypt() {
  if $VERACRYPT_MOUNTED; then
    log "🔒 Dismounting VeraCrypt volume..."
    if "$VERACRYPT_CLI" --text --non-interactive --dismount "$VERACRYPT_MOUNT" 2>>"$LOG_FILE"; then
      VERACRYPT_MOUNTED=false
      log "✅ VeraCrypt volume dismounted and locked."
    else
      error "Failed to dismount VeraCrypt volume at: $VERACRYPT_MOUNT"
      error "Please dismount it manually in the VeraCrypt app before unplugging the drive."
    fi
  fi
}

# -----------------------------------------------------------------------------
# Cleanup — always runs on exit (normal finish, crash, or Ctrl+C).
# Guarantees the VeraCrypt volume is never left mounted and unlocked.
# -----------------------------------------------------------------------------
cleanup() {
  log ""
  log "--- Cleanup triggered ---"
  unmount_veracrypt
  log "===== Script exited ====="
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
log "===== iCloud Backup Started ====="
log "Source     : $ICLOUD_DIR"
log "Destination: $BACKUP_DIR"
log "VeraCrypt  : $($USE_VERACRYPT && echo "YES — $VERACRYPT_VOLUME" || echo "NO")"
log "Log file   : $LOG_FILE"
$DRY_RUN && log "Mode       : DRY RUN" || log "Mode       : LIVE"
echo ""

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
if [[ ! -d "$ICLOUD_DIR" ]]; then
  error "iCloud Drive directory not found: $ICLOUD_DIR"
  exit 1
fi

# -----------------------------------------------------------------------------
# Mount VeraCrypt volume if requested
# -----------------------------------------------------------------------------
if $USE_VERACRYPT && ! $DRY_RUN; then
  mount_veracrypt
elif $USE_VERACRYPT && $DRY_RUN; then
  log "⚠️  DRY RUN: Skipping VeraCrypt mount. Would mount: $VERACRYPT_VOLUME → $VERACRYPT_MOUNT"
fi

# -----------------------------------------------------------------------------
# Verify destination is available and writable
# -----------------------------------------------------------------------------
if ! $DRY_RUN; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    log "Backup destination not found — creating: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
  fi

  if [[ ! -w "$BACKUP_DIR" ]]; then
    error "Backup destination is not writable: $BACKUP_DIR"
    exit 1
  fi

  # Warn if less than 1 GB free on destination
  FREE_KB=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  FREE_GB=$(( FREE_KB / 1048576 ))
  FREE_GB_FRAC=$(( (FREE_KB % 1048576) * 10 / 1048576 ))
  log "Destination free space: ${FREE_GB}.${FREE_GB_FRAC} GB"
  if (( FREE_KB < 1048576 )); then
    error "Less than 1 GB free on destination (${FREE_GB}.${FREE_GB_FRAC} GB). Aborting."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# rsync options
#   -a             archive mode (permissions, timestamps, symlinks, etc.)
#   -u             skip files that are newer on destination (overwrite if newer)
#   -h             human-readable sizes
#   --progress     per-file progress
#   --ignore-errors  keep going on read errors
# -----------------------------------------------------------------------------
RSYNC_OPTS=(-a -u -h --progress --ignore-errors --log-file="$LOG_FILE")
$DRY_RUN && RSYNC_OPTS+=(--dry-run)

# -----------------------------------------------------------------------------
# Main loop — iterate over every top-level item in iCloud Drive
# -----------------------------------------------------------------------------
log ""
log "Scanning iCloud Drive..."

FOLDER_COUNT=0
SUCCESS_COUNT=0

for ITEM in "$ICLOUD_DIR"/*; do
  [[ ! -e "$ITEM" ]] && continue

  ITEM_NAME="$(basename "$ITEM")"

  # ----------------------------------------------------------
  # Trigger iCloud download for this item
  # ----------------------------------------------------------
  if ! $DRY_RUN; then
    log "⬇️  Triggering iCloud download for: $ITEM_NAME"

    # Download the top-level item and any nested .icloud stubs individually,
    # since brctl download does not recurse into subdirectories.
    brctl download "$ITEM" 2>>"$LOG_FILE" || log "   (brctl download skipped — may already be local)"
    if [[ -d "$ITEM" ]]; then
      while IFS= read -r -d '' STUB; do
        brctl download "$STUB" 2>>"$LOG_FILE" || true
      done < <(find "$ITEM" -name "*.icloud" -type f -print0 2>/dev/null)
    fi

    log "   Waiting for download to complete..."
    WAIT=0
    while find "$ITEM" -name "*.icloud" -type f 2>/dev/null | grep -q .; do
      sleep 5
      WAIT=$((WAIT + 5))
      if (( WAIT >= 300 )); then
        error "Timed out waiting for download of: $ITEM_NAME — skipping"
        continue 2
      fi
    done
    log "   ✅ Download complete (waited ${WAIT}s)"
  fi

  # ----------------------------------------------------------
  # rsync to destination
  # ----------------------------------------------------------
  log "📦 Copying: $ITEM_NAME → $BACKUP_DIR/"
  if rsync "${RSYNC_OPTS[@]}" "$ITEM" "$BACKUP_DIR/" 2>>"$LOG_FILE"; then
    log "   ✅ Copy succeeded: $ITEM_NAME"
    ((SUCCESS_COUNT++)) || true

    # Evict from local Mac storage to free up space for the next folder
    if ! $DRY_RUN; then
      log "🗑️  Evicting from local storage: $ITEM_NAME"
      brctl evict "$ITEM" 2>>"$LOG_FILE" \
        && log "   ✅ Evicted: $ITEM_NAME" \
        || log "   ⚠️  Eviction skipped (may not be evictable): $ITEM_NAME"
    fi
  else
    error "rsync failed for: $ITEM_NAME — skipping eviction"
  fi

  ((FOLDER_COUNT++)) || true
  echo ""
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log "===== Backup Complete ====="
log "Items processed : $FOLDER_COUNT"
log "Items succeeded : $SUCCESS_COUNT"
log "Errors          : $ERROR_COUNT"
log "Log saved to    : $LOG_FILE"

if (( ERROR_COUNT > 0 )); then
  log "⚠️  Completed with $ERROR_COUNT error(s). Review the log for details."
  exit 1
else
  log "🎉 All items backed up successfully."
  exit 0
fi
# Note: the trap on EXIT automatically dismounts VeraCrypt after this point
