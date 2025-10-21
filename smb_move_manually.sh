#!/usr/bin/env bash
#
# smb_move_manually.sh
#
# Moves (uploads then deletes) all files & folders from $HOME/Videos/torrents
# to //192.168.1.176/Media/Torrents using smbclient, preserving subfolders.
#
# ⚠️ Security note: credentials are embedded and will be visible to anyone
#   who can read this file and may briefly appear in process listings.
#   Keep permissions strict: chmod 700 smb_move_manually.sh
#
set -euo pipefail
IFS=$'\n\t'

# ==== USER CONFIG (you provided these) ====
SMB_SERVER="//192.168.1.176/Media"
SMB_USER="media"
SMB_PASS="changeMe123"

# smbclient options
SMB_TIMEOUT=0           # seconds
# SMB_EXTRA_OPTS=()        # e.g. force protocol: SMB_EXTRA_OPTS=(-m SMB3)
# If you suspect dialect issues with your NAS, uncomment the next line:
SMB_EXTRA_OPTS=(-m SMB3)

# Local and remote paths
LOCAL_DIR="${LOCAL_DIR:-"$HOME/Videos/torrents/ready"}"
REMOTE_DIR="${REMOTE_DIR:-"/Torrents"}"   # folder inside the share

# Optional: set DRY_RUN=1 to test without changing anything
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "[$(date '+%Y-%m-%d %H:%M:%S')]" "$*"; }

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Required binary not found: $1" >&2
    exit 2
  fi
}

require_bin smbclient

if [[ ! -d "$LOCAL_DIR" ]]; then
  log "Local directory does not exist or is empty: $LOCAL_DIR"
  exit 0
fi

# Ensure remote directory exists (best-effort; ignore error if it already exists)
ensure_remote_dir() {
  local remote="$1"
  log "Ensuring remote directory exists: $remote"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would create remote dir '$remote' if missing"
    return 0
  fi
  smbclient "$SMB_SERVER" -U "${SMB_USER}%${SMB_PASS}" <<EOF >/dev/null 2>&1 || true
mkdir "$remote"
quit
EOF
}

# Upload a single file or directory.
# For directories, turns recurse ON and mput the directory name to copy its tree.
upload_item() {
  local item="$1"
  local base parent
  base="$(basename "$item")"
  parent="$(dirname "$item")"

  log "Uploading: $item  ->  $SMB_SERVER$REMOTE_DIR/$base"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would upload '$item'"
    return 0
  fi

  smbclient "$SMB_SERVER" -U "${SMB_USER}%${SMB_PASS}" -t "$SMB_TIMEOUT" "${SMB_EXTRA_OPTS[@]}" <<EOF >/dev/null
cd "$REMOTE_DIR"
recurse ON
prompt OFF
lcd "$parent"
mput "$base"
quit
EOF
}

remove_local_item() {
  local item="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would remove '$item'"
    return 0
  fi
  if [[ -e "$item" && "$item" == "$LOCAL_DIR"* ]]; then
    log "Removing local: $item"
    # rm -rf -- "$item"
  fi
}

# ===== Main =====
ensure_remote_dir "$REMOTE_DIR"

shopt -s nullglob dotglob
mapfile -t entries < <(find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -print0 | xargs -0 -I{} printf "%s\n" "{}")

if ((${#entries[@]} == 0)); then
  log "Nothing to move in: $LOCAL_DIR"
  exit 0
fi

fail_count=0
for path in "${entries[@]}"; do
  if upload_item "$path"; then
    remove_local_item "$path"
  else
    log "[ERROR] Failed to upload: $path"
    ((fail_count++)) || true
  fi
done

if ((fail_count > 0)); then
  log "[WARN] Completed with $fail_count failed item(s)."
  exit 1
else
  log "All items moved successfully."
  exit 0
fi
