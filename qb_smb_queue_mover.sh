#!/usr/bin/env bash
# qb_smb_queue_mover.sh — qBittorrent "Run on torrent finished" handler with a persistent queue
# Usage in qBittorrent:
#   /path/to/qb_smb_queue_mover.sh "%F" "%N" "%D"
# Test with: https://webtorrent.io/free-torrents
# and: https://academictorrents.com/details/8c271f4d2e92a3449e2d1bde633cd49f64af888f
#
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
IFS=$'\n\t'

########################################
#            CONFIGURATION             #
########################################
SMB_SERVER="//192.168.1.176/Media"
SMB_USER="media"
SMB_PASS="changeMe123"

# Base dir on the share
REMOTE_BASE="/Torrents"

# Logging & queue
LOG_DIR="${HOME}/Videos/torrents"
LOG_FILE="${LOG_DIR}/qb-smb-mover.log"
QUEUE_DIR="${LOG_DIR}/.queue"
LOCKFILE="${LOG_DIR}/.qb-smb-mover.lock"
PAUSE_FILE="${LOG_DIR}/.pause"         # create this file to pause after current job

# Networking / retries
MAX_RETRIES=3
INITIAL_BACKOFF=2
VERIFY_TIMEOUT=0         # seconds; 0 = unlimited
MAX_JOB_RETRIES=4
REQUEUE_SLEEP=3

# smbclient options
SMB_TIMEOUT=0           # seconds
# SMB_EXTRA_OPTS=()        # e.g. force protocol: SMB_EXTRA_OPTS=(-m SMB3)
# If you suspect dialect issues with your NAS, uncomment the next line:
SMB_EXTRA_OPTS=(-m SMB3)
########################################
#          END CONFIGURATION           #
########################################

mkdir -p "$LOG_DIR" "$QUEUE_DIR"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { printf "[%s] %s\n" "$(timestamp)" "$*" | tee -a "$LOG_FILE"; }

require_bin() { command -v "$1" >/dev/null 2>&1 || { log "[ERROR] Missing binary: $1"; exit 2; }; }
require_bin smbclient
require_bin find
require_bin awk
require_bin stat
require_bin flock
require_bin realpath

sanitize_name() {
  local s="$1"
  s="${s//\//_}"
  s="$(printf '%s' "$s" | tr -d '\000-\031')"   # strip control chars
  s="$(printf '%s' "$s" | awk '{$1=$1; print}')" # trim
  printf '%s' "$s"
}

# ---- smbclient with diagnostics ----
run_smb() {
  # $1 = command string for -c
  local cmd="$1" tmpout
  tmpout="$(mktemp)"
  if ! smbclient "$SMB_SERVER" -U "${SMB_USER}%${SMB_PASS}" -t "$SMB_TIMEOUT" "${SMB_EXTRA_OPTS[@]}" -c "$cmd" >"$tmpout" 2>&1; then
    log "[SMB ERROR] smbclient command failed"
    log "  -c $cmd"
    sed 's/^/[SMB] /' "$tmpout" | tee -a "$LOG_FILE" >/dev/null
    rm -f "$tmpout"
    return 1
  fi
  rm -f "$tmpout"
  return 0
}

remote_mkdir_p() {
  local path="$1"
  local IFS='/'; local parts=($path); local current=""
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    current="${current}/$p"
    # Try to create and immediately ls it (logs real error if any)
    run_smb "mkdir \"$current\"; ls \"$current\"" || return 1
  done
  return 0
}

# Upload one file with robust resume until remote size == local size.
# Uses: remote_file_size, run_smb, log, INITIAL_BACKOFF, MAX_RETRIES
smb_put_one_file() {
  local local_path="$1" rparent="$2" rname="$3"

  local lsz; lsz="$(stat -c '%s' -- "$local_path" || echo 0)"
  if [[ "$lsz" -le 0 ]]; then
    log "[ERROR] Local file has zero size or missing: $local_path"
    return 1
  fi

  # Make sure remote parent exists
  remote_mkdir_p "$rparent" || return 1

  local attempt=1
  local backoff="$INITIAL_BACKOFF"
  local last_remote=-1
  local same_count=0
  local SAME_LIMIT=6        # ~6 checks with no progress -> backoff & reconnect
  local CHECK_INTERVAL=5    # seconds between progress checks

  while :; do
    # Current remote size
    local rsz; rsz="$(remote_file_size "$rparent" "$rname")"
    [[ -z "$rsz" ]] && rsz=0
    log "Upload progress: $rparent/$rname : remote=$rsz local=$lsz"

    if (( rsz >= lsz )); then
      # Done!
      return 0
    fi

    # Try to (re)send remainder using reput. reput resumes at remote size.
    # Note: avoid lcd tricks; pass absolute local path.
    if ! run_smb "cd \"$rparent\"; prompt OFF; reput \"$(realpath -s "$local_path")\" \"$rname\""; then
      log "[WARN] reput call failed for: $local_path -> $rparent/$rname"
    fi

    # Wait and re-check progress a few times before deciding it stalled
    local i
    for (( i=0; i<SAME_LIMIT; i++ )); do
      sleep "$CHECK_INTERVAL"
      rsz="$(remote_file_size "$rparent" "$rname")"
      [[ -z "$rsz" ]] && rsz=0
      log "Upload progress: $rparent/$rname : remote=$rsz local=$lsz"

      if (( rsz >= lsz )); then
        return 0
      fi
      if (( rsz == last_remote )); then
        same_count=$((same_count+1))
      else
        same_count=0
        last_remote="$rsz"
      fi

      # If we saw progress (remote size increased), break early to reput again
      if (( rsz > last_remote )); then
        break
      fi
    done

    # If no progress over SAME_LIMIT intervals, back off and retry
    if (( same_count >= SAME_LIMIT )); then
      if (( attempt >= MAX_RETRIES )); then
        log "[ERROR] Upload stalled after $attempt attempt(s): $local_path -> $rparent/$rname"
        return 1
      fi
      log "[WARN] Upload stalled; backing off ${backoff}s (attempt $attempt/$MAX_RETRIES)"
      sleep "$backoff"
      attempt=$((attempt+1))
      backoff=$((backoff*2))
      same_count=0
      last_remote=-1
    fi
  done
}

smb_put_file() {
  local src="$1" rdir="$2" base; base="$(basename "$src")"
  smb_put_one_file "$src" "$rdir" "$base"
  run_smb "cd \"$rdir\"; allinfo \"$base\"" || true
}

# Upload a directory tree by walking locally and issuing precise puts (no mput), with resume.
# args: srcdir (absolute or relative local dir), rdir (remote parent dir, e.g. /Torrents)
smb_put_dir_recursive() {
  local srcdir="$1" rdir="$2"
  srcdir="$(realpath -s "$srcdir")" || return 1
  local topname; topname="$(basename "$srcdir")"

  # 1) Ensure remote top directory exists
  remote_mkdir_p "$rdir/$topname" || return 1

  # 2) Create subdirectories (parents before children)
  while IFS= read -r -d '' d; do
    local rel rpath
    rel="$(realpath --relative-to="$srcdir" "$d")" || rel="${d#$srcdir/}"
    [[ "$rel" == "." || -z "$rel" ]] && continue
    rpath="$rdir/$topname/$rel"
    remote_mkdir_p "$rpath" || return 1
  done < <(find "$srcdir" -type d -print0)

  # 3) Upload files with resume
  while IFS= read -r -d '' f; do
    local rel rparent rname
    rel="$(realpath --relative-to="$srcdir" "$f")" || rel="${f#$srcdir/}"
    rparent="$(dirname "$rdir/$topname/$rel")"
    rname="$(basename "$f")"

    if ! smb_put_one_file "$f" "$rparent" "$rname"; then
      log "[WARN] put failed for: $f -> $rparent/$rname"
      return 1
    fi
  done < <(find "$srcdir" -type f -print0)

  return 0
}

remote_file_size() {
  local rdir="$1" rname="$2"
  local out
  out="$(smbclient "$SMB_SERVER" -U "${SMB_USER}%${SMB_PASS}" -t "$SMB_TIMEOUT" \
         "${SMB_EXTRA_OPTS[@]}" \
         -c "cd \"$rdir\"; allinfo \"$rname\"" 2>/dev/null || true)"

  # Parse size robustly:
  # - Accept exact integers: "size: 2302220197"
  # - Accept scientific:     "2.30222e+09 bytes"
  # - Accept with commas:    "2,302,220,197 bytes"
  # Always print a plain integer (no scientific).
  local bytes
  bytes="$(printf '%s\n' "$out" | awk '
    BEGIN {
      found = 0
      # Force non-scientific integer printing when we printf later.
      OFMT="%.0f"
      CONVFMT="%.17g"
    }
    /[Ss][Ii][Zz][Ee][[:space:]]*:|[Ss][Tt][Rr][Ee][Aa][Mm].*bytes/ {
      for (i=1; i<=NF; i++) {
        tok = $i
        # Case 1: scientific notation like 2.30222e+09
        if (tok ~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)$/) {
          val = tok + 0
          printf "%.0f\n", val
          found = 1
          exit
        }
        # Case 2: integer possibly with separators: 2,302,220,197
        gsub(/[^0-9]/, "", tok)
        if (tok ~ /^[0-9]+$/) {
          val = tok + 0
          printf "%.0f\n", val
          found = 1
          exit
        }
      }
    }
    END {
      if (!found) print 0
    }
  ')"

  if [[ "${bytes:-0}" -eq 0 ]]; then
    log "[SMB DIAG] allinfo returned zero; sample for \"$rdir/$rname\":"
    printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/[SMB] /' | tee -a "$LOG_FILE" >/dev/null
  fi

  printf '%s' "${bytes:-0}"
}

# Sum remote bytes for a directory by enumerating LOCAL files
# and querying the exact remote file with allinfo.
remote_dir_size_from_local() {
  local local_root="$1"    # e.g., /home/.../Nausicaä ...
  local remote_root="$2"   # e.g., /Torrents/Nausicaä ...   (see policy fix below)
  local total=0

  while IFS= read -r -d '' f; do
    # Compute path relative to local_root (literal, robust)
    local rel
    rel="$(realpath --relative-to="$local_root" "$f")" || rel="${f#$local_root/}"

    # Map to remote path
    local rdir rname
    rdir="$(dirname "$remote_root/$rel")"
    rname="$(basename "$f")"

    # Exact file size on remote
    local sz
    sz="$(remote_file_size "$rdir" "$rname")"
    [[ -n "$sz" ]] || sz=0
    total=$(( total + sz ))
  done < <(find "$local_root" -type f -print0)

  printf '%s' "$total"
}

# --- Wrapper: compute remote size for file OR directory path ---
remote_sum_sizes() {
  local rpath="$1"
  # Determine if path is file or directory by probing with allinfo first.
  # Try as file in its parent dir; if size=0 and LS says it looks like a dir, fall back to dir sum.
  local parent base size
  parent="$(dirname "$rpath")"
  base="$(basename "$rpath")"
  parent="/${parent#/}"   # ensure single leading slash

  size="$(remote_file_size "$parent" "$base")"
  if [[ "$size" -gt 0 ]]; then
    printf '%s' "$size"
    return 0
  fi
  # Fallback: treat as directory tree
  remote_dir_size "$rpath"
}

local_sum_sizes() {
  local p="$1"
  if [[ -f "$p" ]]; then
    stat -c '%s' -- "$p"
  else
    # ensure awk prints integer only
    find "$p" -type f -printf '%s\n' | awk '{s+=$1} END{printf "%.0f", s}'
  fi
}

verify_upload() {
  local local_path="$1" remote_path="$2" start tnow
  start=$(date +%s)
  local is_file=0
  [[ -f "$local_path" ]] && is_file=1

  while true; do
    local lb rb
    lb="$(local_sum_sizes "$local_path" || echo 0)"

    if (( is_file )); then
      local rdir rname
      rdir="$(dirname "$remote_path")"
      rname="$(basename "$remote_path")"
      rb="$(remote_file_size "$rdir" "$rname")"
    else
      # Precise per-file sum using allinfo for each file
      rb="$(remote_dir_size_from_local "$local_path" "$remote_path")"
    fi

    log "Verify sizes: local=$(printf '%.0f' "$lb") remote=$(printf '%.0f' "$rb") [${remote_path}]"

    # Sanity guard: if remote is unexpectedly > local by a large factor, consider it a mismatch.
    # (Catches any future parsing bugs or server anomalies.)
    if (( rb >= lb && lb > 0 && rb <= lb * 105 / 100 )); then
      return 0
    fi

    if (( VERIFY_TIMEOUT > 0 )); then
      tnow=$(date +%s)
      (( tnow - start >= VERIFY_TIMEOUT )) && { log "[WARN] Verify timeout"; return 1; }
    fi
    sleep 2
  done
}

with_retries() {
  local desc="$1"; shift
  local attempt=1 backoff=$INITIAL_BACKOFF
  while true; do
    if "$@"; then return 0; fi
    if (( attempt >= MAX_RETRIES )); then
      log "[ERROR] $desc failed after $attempt attempt(s)"
      return 1
    fi
    log "[WARN] $desc failed (attempt $attempt). Retrying in ${backoff}s..."
    sleep "$backoff"
    attempt=$((attempt+1)); backoff=$((backoff*2))
  done
}

delete_local() {
  local p="$1"
  [[ -e "$p" ]] && { log "Deleting local: $p"; rm -rf -- "$p"; }
}

# ---- queue ----
enqueue_job() {
  local F="$1" N="$2" D="$3"
  local ts rand job

  ts=$(date +%s)
  rand=$RANDOM
  job="${QUEUE_DIR}/${ts}-${rand}.job"

  printf 'F=%q\nN=%q\nD=%q\nRETRIES=0\n' "$F" "$N" "$D" > "$job"
  echo "$job"
}

resolve_local_path() {
  local F="$1" D="$2"
  if [[ "$F" = /* ]]; then printf '%s' "$F"; else printf '%s/%s' "${D%/}" "$F"; fi
}

process_job() {
  local job="$1"
  # shellcheck disable=SC1090
  . "$job" || { log "[ERROR] Unable to read job $job"; return 1; }

  # Resolve what actually finished on disk (file OR directory).
  local LOCAL_PATH
  LOCAL_PATH="$(resolve_local_path "$F" "$D")"

  if [[ ! -e "$LOCAL_PATH" ]]; then
    log "[ERROR] Missing local path for job $job: $LOCAL_PATH"
    return 1
  fi

  # Use the REAL on-disk basename for remote naming (preserves accents, avoids %N mismatch)
  local BASE
  BASE="$(basename "$LOCAL_PATH")"

  # Files go directly under /Torrents; directories replicate their basename under /Torrents
  local REMOTE_DIR REMOTE_TARGET
  REMOTE_DIR="${REMOTE_BASE%/}"               # always cd into /Torrents
  if [[ -f "$LOCAL_PATH" ]]; then
    REMOTE_TARGET="${REMOTE_DIR}/${BASE}"     # /Torrents/<file>
  else
    REMOTE_TARGET="${REMOTE_DIR}/${BASE}"     # /Torrents/<dir>
  fi

  log "Processing job:"
  log "  Local path: $LOCAL_PATH"
  log "  Remote dir: $REMOTE_DIR"
  log "  Remote target: $REMOTE_TARGET"

  # Ensure /Torrents exists (and is writable)
  with_retries "mkdir -p $REMOTE_DIR" remote_mkdir_p "$REMOTE_DIR" || return 1

  # Upload and verify
  if [[ -f "$LOCAL_PATH" ]]; then
    log "Uploading file: $BASE -> $REMOTE_DIR"
    if ! with_retries "put file" smb_put_file "$LOCAL_PATH" "$REMOTE_DIR"; then
      return 1
    fi
    # Verify the exact remote file (your verify_upload handles file vs dir)
    if verify_upload "$LOCAL_PATH" "$REMOTE_TARGET"; then
      delete_local "$LOCAL_PATH"
      log "[OK] File moved."
      return 0
    else
      log "[ERROR] Verification failed for file: $REMOTE_TARGET"
      return 1
    fi

  elif [[ -d "$LOCAL_PATH" ]]; then
    log "Uploading directory: $BASE -> $REMOTE_DIR"
    if ! with_retries "put directory" smb_put_dir_recursive "$LOCAL_PATH" "$REMOTE_DIR"; then
      return 1
    fi
    # After mput <BASE>, the server creates /Torrents/<BASE>/...
    if verify_upload "$LOCAL_PATH" "$REMOTE_TARGET"; then
      delete_local "$LOCAL_PATH"
      log "[OK] Directory moved."
      return 0
    else
      log "[ERROR] Verification failed for directory: $REMOTE_TARGET"
      return 1
    fi

  else
    log "[ERROR] Path is neither file nor directory: $LOCAL_PATH"
    return 1
  fi
}

bump_retry_or_fail() {
  local job="$1"
  # shellcheck disable=SC1090
  . "$job" || return 1
  local r="${RETRIES:-0}"
  r=$((r+1))
  if (( r > MAX_JOB_RETRIES )); then
    log "[ERROR] Job exceeded max retries, leaving for manual review: $job"
    return 0
  fi
  awk -v R="$r" 'BEGIN{updated=0}
    /^RETRIES=/ {print "RETRIES="R; updated=1; next}
    {print}
    END{if(!updated) print "RETRIES="R}
  ' "$job" > "${job}.tmp" && mv "${job}.tmp" "$job"
  log "[INFO] Requeued with RETRIES=$r: $job"
  sleep "$REQUEUE_SLEEP"
}

drain_queue() {
  while true; do
    [[ -f "$PAUSE_FILE" ]] && { log "[INFO] Pause requested; stopping worker."; break; }
    mapfile -t jobs < <(ls -1 "${QUEUE_DIR}"/*.job 2>/dev/null || true)
    ((${#jobs[@]}==0)) && { log "[INFO] Queue empty."; break; }
    for job in "${jobs[@]}"; do
      log "----- Start job ${job##*/} -----"
      if process_job "$job"; then
        rm -f -- "$job"; log "----- Done job ${job##*/} -----"
      else
        bump_retry_or_fail "$job" || true
        log "----- Failed job ${job##*/} (kept) -----"
      fi
      [[ -f "$PAUSE_FILE" ]] && { log "[INFO] Pause requested; stopping after this job."; break; }
    done
  done
}

graceful_exit() { log "[INFO] Caught termination; exiting gracefully."; exit 0; }
trap graceful_exit SIGINT SIGTERM

# ---- entrypoint ----
if (( $# != 3 )); then log "[ERROR] Expected 3 parameters: %F %N %D ; got $#"; exit 2; fi
JOB_FILE=$(enqueue_job "$1" "$2" "$3")
log "[INFO] Enqueued job: ${JOB_FILE##*/}"

# Acquire worker lock and run a preflight once
exec 200>"$LOCKFILE"
if flock -w 1800 200; then
  log "[INFO] Acquired worker lock; running preflight..."
  # Preflight (auth + write)
  log "[INFO] SMB preflight: credentials and /Torrents writable?"
  if ! run_smb "ls" ; then
    log "[ERROR] Cannot list share root; leaving jobs queued."; exit 1
  fi
  if ! remote_mkdir_p "$REMOTE_BASE" ; then
    log "[ERROR] Cannot create/access $REMOTE_BASE; leaving jobs queued."; exit 1
  fi
  # Tiny write test
  tmpf="/tmp/.qb-smb-preflight.$RANDOM"; echo ok > "$tmpf"
  if ! run_smb "cd \"$REMOTE_BASE\"; put \"$tmpf\" preflight.txt; rm preflight.txt" ; then
    rm -f "$tmpf"; log "[ERROR] No write permission in $REMOTE_BASE; leaving jobs queued."; exit 1
  fi
  rm -f "$tmpf"
  log "[INFO] SMB preflight passed; draining queue..."
  drain_queue
  log "[INFO] Worker finished; releasing lock."
else
  log "[INFO] Another worker is active; leaving job queued."
fi

exit 0
