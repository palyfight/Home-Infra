#!/usr/bin/env bash
#
# upload_folder_and_delete_to_smb.sh
#
# This script is meant to be used with qBittorrent’s “Run external program on torrent completion”.
# It uploads a completed folder (or file) to the SMB share under remote base directory,
# ensuring the remote folder exists (creating if needed), performs the upload recursively,
# and on success deletes the local copy.
#
# Usage: upload_folder_and_delete_to_smb.sh "<local_path>"
#
# Prerequisites: Must have smbclient installed and accessible in PATH. e.g.: sudo apt install smbclient
#

# ========== CONFIGURATION ==========
SMB_SERVER="//192.168.1.176/Media"
SMB_USER="media"
SMB_PASS="changeMe123"
REMOTE_BASE_DIR="Torrents"         # base remote folder inside the share
LOCAL_PATH="$HOME/Videos/torrents/$1" # Must be the path where qbittorrent downloads the torrent.

LOG_DIR="$HOME/Videos/torrents"
LOG_FILE="${LOG_DIR}/upload_folder_and_delete.log"

# ========== LOGGING FUNCTIONS ==========
mkdir -p "$LOG_DIR"

log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${ts} [${level}] $*" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

# ========== MAIN SCRIPT ==========

if [ -z "$LOCAL_PATH" ]; then
    error "No local path provided. Exiting."
    exit 1
fi

if [ ! -e "$LOCAL_PATH" ]; then
    error "Local path does not exist: ${LOCAL_PATH}"
    exit 2
fi

BASENAME=$(basename "$LOCAL_PATH")
REMOTE_TARGET_PATH="${REMOTE_BASE_DIR}/${BASENAME}"

info "Script started for local path: ${LOCAL_PATH}"
info "Preparing to upload to SMB share ${SMB_SERVER}/${REMOTE_TARGET_PATH}"

# Step 1: Create remote folder if not exists (one level only)
# Note: smbclient mkdir does not support mkdir -p, so we attempt mkdir and ignore error if it already exists.

info "Ensuring remote directory exists: ${REMOTE_BASE_DIR}/${BASENAME}"
smbclient "${SMB_SERVER}" -U "${SMB_USER}%${SMB_PASS}" -c "cd \"${REMOTE_BASE_DIR}\"; mkdir \"${BASENAME}\"" \
    && info "Created remote folder: ${REMOTE_TARGET_PATH}" \
    || info "Remote folder may already exist or mkdir failed with benign error"

# Step 2: Upload using recursion if it’s a directory, or simple put if file
if [ -d "$LOCAL_PATH" ]; then
    info "Detected a directory for upload: ${LOCAL_PATH}"
    smbclient "${SMB_SERVER}" -U "${SMB_USER}%${SMB_PASS}" -c "cd \"${REMOTE_TARGET_PATH}\"; recurse ON; prompt OFF; lcd \"$(dirname "${LOCAL_PATH}")\"; mput \"${BASENAME}/*\""
    UPLOAD_EXIT_CODE=$?
elif [ -f "$LOCAL_PATH" ]; then
    info "Detected a file for upload: ${LOCAL_PATH}"
    smbclient "${SMB_SERVER}" -U "${SMB_USER}%${SMB_PASS}" -c "cd \"${REMOTE_BASE_DIR}\"; put \"${LOCAL_PATH}\" \"${BASENAME}\""
    UPLOAD_EXIT_CODE=$?
else
    error "Local path is neither file nor directory: ${LOCAL_PATH}"
    exit 3
fi

if [ $UPLOAD_EXIT_CODE -ne 0 ]; then
    error "Upload failed for ${LOCAL_PATH}, smbclient exit code ${UPLOAD_EXIT_CODE}"
    exit 4
fi

info "Upload succeeded for ${LOCAL_PATH} → ${REMOTE_TARGET_PATH}"

# Step 3: Delete local path
if [ -d "$LOCAL_PATH" ]; then
    info "Deleting local directory ${LOCAL_PATH}"
    rm -rf "$LOCAL_PATH" || { error "Failed to delete local directory ${LOCAL_PATH}"; exit 5; }
elif [ -f "$LOCAL_PATH" ]; then
    info "Deleting local file ${LOCAL_PATH}"
    rm "$LOCAL_PATH" || { error "Failed to delete local file ${LOCAL_PATH}"; exit 6; }
fi

info "Script completed successfully"
exit 0
