#!/usr/bin/env bash
# icloud_backup.sh — Back up iCloud Drive to an external drive, folder by folder.
# See README.md for full documentation, setup instructions, and examples.
#
# Usage: ./icloud_backup.sh [--dry-run] [--veracrypt] [--mirror] [--verify] [--exclude=PATTERN ...]

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration defaults — override via ~/.icloud_backup.conf or env vars
# -----------------------------------------------------------------------------
ICLOUD_DIR="${ICLOUD_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs}"
BACKUP_DIR="${BACKUP_DIR:-/Volumes/iCloudBackup}"
VERACRYPT_VOLUME="${VERACRYPT_VOLUME:-/Volumes/MyExternalDrive/encrypted.vc}"
VERACRYPT_MOUNT="${VERACRYPT_MOUNT:-/Volumes/iCloudBackup}"
VERACRYPT_CLI="${VERACRYPT_CLI:-/Applications/VeraCrypt.app/Contents/MacOS/VeraCrypt}"

# Source user config file if it exists (overrides the defaults above)
CONF_FILE="${ICLOUD_BACKUP_CONF:-$HOME/.icloud_backup.conf}"
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
fi

# -----------------------------------------------------------------------------
# Parse flags
# -----------------------------------------------------------------------------
DRY_RUN=false
USE_VERACRYPT=false
MIRROR=false
VERIFY=false
EXCLUDES=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --veracrypt)  USE_VERACRYPT=true ;;
    --mirror)     MIRROR=true ;;
    --verify)     VERIFY=true ;;
    --exclude=*)  EXCLUDES+=("${arg#--exclude=}") ;;
    *)
      echo "Unknown flag: $arg"
      echo "Usage: $0 [--dry-run] [--veracrypt] [--mirror] [--verify] [--exclude=PATTERN ...]"
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Log setup — logs stored in ~/Library/Logs/icloud-backup/
# Old logs beyond the most recent 10 are automatically removed.
# -----------------------------------------------------------------------------
LOG_DIR="$HOME/Library/Logs/icloud-backup"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/icloud_backup_$(date +%Y%m%d_%H%M%S).log"
ERROR_COUNT=0

# Auto-cleanup: keep only the 10 most recent log files
while IFS= read -r OLD_LOG; do
  rm -f "$OLD_LOG"
done < <(ls -1t "$LOG_DIR"/icloud_backup_*.log 2>/dev/null | tail -n +11)

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
    error "Please create the volume first — see README.md for setup instructions."
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
log "Mirror     : $($MIRROR && echo "YES (--delete)" || echo "NO (incremental only)")"
if (( ${#EXCLUDES[@]} > 0 )); then
  log "Excludes   : ${EXCLUDES[*]}"
fi
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
#   --delete       (mirror mode only) remove files from dest not in source
# -----------------------------------------------------------------------------
RSYNC_OPTS=(-a -u -h --progress --ignore-errors --log-file="$LOG_FILE")
$DRY_RUN && RSYNC_OPTS+=(--dry-run)
$MIRROR && RSYNC_OPTS+=(--delete)
for EXCL in "${EXCLUDES[@]}"; do
  RSYNC_OPTS+=(--exclude="$EXCL")
done

# -----------------------------------------------------------------------------
# Main loop — iterate over every top-level item in iCloud Drive
# -----------------------------------------------------------------------------
log ""
log "Scanning iCloud Drive..."

FOLDER_COUNT=0
SUCCESS_COUNT=0

# Count total items for progress display
TOTAL_ITEMS=0
for _ITEM in "$ICLOUD_DIR"/*; do
  [[ -e "$_ITEM" ]] && ((TOTAL_ITEMS++)) || true
done
log "Found $TOTAL_ITEMS items in iCloud Drive"

for ITEM in "$ICLOUD_DIR"/*; do
  [[ ! -e "$ITEM" ]] && continue

  ((FOLDER_COUNT++)) || true
  ITEM_NAME="$(basename "$ITEM")"
  log "--- [$FOLDER_COUNT/$TOTAL_ITEMS] $ITEM_NAME ---"

  # ----------------------------------------------------------
  # Skip excluded items (avoids unnecessary iCloud downloads)
  # ----------------------------------------------------------
  SKIP=false
  for EXCL in "${EXCLUDES[@]}"; do
    # Match exact folder name or shell glob pattern
    if [[ "$ITEM_NAME" == $EXCL ]]; then
      SKIP=true
      break
    fi
  done
  if $SKIP; then
    log "⏭️  Skipping excluded item: $ITEM_NAME"
    continue
  fi

  # ----------------------------------------------------------
  # Skip items already up-to-date on destination
  # ----------------------------------------------------------
  if ! $DRY_RUN && [[ -e "$BACKUP_DIR/$ITEM_NAME" ]]; then
    # A dry-run rsync with -i (itemize) shows what would transfer;
    # empty output means the destination is already current.
    CHANGES=$(rsync -a -u -i --dry-run "$ITEM" "$BACKUP_DIR/" 2>/dev/null | head -5)
    if [[ -z "$CHANGES" ]]; then
      log "⏭️  Already up-to-date: $ITEM_NAME"
      ((SUCCESS_COUNT++)) || true
      continue
    fi
  fi

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
  # Per-item disk space check
  # ----------------------------------------------------------
  if ! $DRY_RUN; then
    ITEM_SIZE_KB=$(du -sk "$ITEM" 2>/dev/null | awk '{print $1}')
    DEST_FREE_KB=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    if (( ITEM_SIZE_KB > DEST_FREE_KB )); then
      ITEM_MB=$(( ITEM_SIZE_KB / 1024 ))
      DEST_MB=$(( DEST_FREE_KB / 1024 ))
      error "Not enough space for $ITEM_NAME (${ITEM_MB} MB needed, ${DEST_MB} MB free) — skipping"
      continue
    fi
  fi

  # ----------------------------------------------------------
  # rsync to destination
  # ----------------------------------------------------------
  log "📦 Copying: $ITEM_NAME → $BACKUP_DIR/"
  if rsync "${RSYNC_OPTS[@]}" "$ITEM" "$BACKUP_DIR/" 2>>"$LOG_FILE"; then
    log "   ✅ Copy succeeded: $ITEM_NAME"

    # Verify backup integrity with checksum comparison
    if $VERIFY && ! $DRY_RUN; then
      log "🔍 Verifying: $ITEM_NAME"
      if rsync -a --checksum --dry-run "$ITEM" "$BACKUP_DIR/" 2>>"$LOG_FILE" | grep -q .; then
        error "Verification failed for: $ITEM_NAME — checksums differ"
      else
        log "   ✅ Verification passed: $ITEM_NAME"
      fi
    fi

    ((SUCCESS_COUNT++)) || true

    # Evict from local Mac storage to free up space for the next folder.
    # Like brctl download, evict does not recurse — evict files individually.
    if ! $DRY_RUN; then
      log "🗑️  Evicting from local storage: $ITEM_NAME"
      if [[ -d "$ITEM" ]]; then
        EVICT_FAILED=false
        while IFS= read -r -d '' FILE; do
          brctl evict "$FILE" 2>>"$LOG_FILE" || EVICT_FAILED=true
        done < <(find "$ITEM" -type f -print0 2>/dev/null)
        $EVICT_FAILED \
          && log "   ⚠️  Some files could not be evicted: $ITEM_NAME" \
          || log "   ✅ Evicted: $ITEM_NAME"
      else
        brctl evict "$ITEM" 2>>"$LOG_FILE" \
          && log "   ✅ Evicted: $ITEM_NAME" \
          || log "   ⚠️  Eviction skipped (may not be evictable): $ITEM_NAME"
      fi
    fi
  else
    error "rsync failed for: $ITEM_NAME — skipping eviction"
  fi

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
