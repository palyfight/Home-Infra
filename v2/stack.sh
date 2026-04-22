#!/usr/bin/env bash
# Manage the v2 homelab stacks.
#
# Usage:
#   ./stack.sh up        Start all stacks in dependency order
#   ./stack.sh down      Stop all stacks in reverse order
#   ./stack.sh restart   Down then up
#   ./stack.sh status    Show running containers per stack
#
# Note on Docker Hub rate limits:
#   On a fresh machine (or after image updates), `up` pulls many images at once
#   and may hit Docker Hub's anonymous pull limit (100 pulls / 6h per IP),
#   failing with "toomanyrequests". When that happens:
#     - Wait a few minutes and re-run `./stack.sh up`. Docker caches layers
#       already pulled, so it resumes where it stopped.
#     - Or run `docker login` once with a free Docker Hub account to double
#       the limit to 200 pulls / 6h.

set -euo pipefail

cd "$(dirname "$0")"

# Ordered from least to most dependent.
# jellyfin creates the `tailscale` network used by traefik-routed services.
STACKS=(
  jellyfin
  immich
  arrs
  extras
  qbit
  plex
  automation
  homepage
)

# Paths that must be real mountpoints before any stack is started. If the NFS
# mount failed (e.g. after a power outage where the server booted before the
# NAS came online), Docker would silently bind-mount an empty local directory
# into media containers — and worse, containers like Immich would start writing
# into it, orphaning data on the host disk. Bail out loudly instead.
REQUIRED_MOUNTS=(
  /mnt/nas
)

require_mounts() {
  local mnt unit
  for mnt in "${REQUIRED_MOUNTS[@]}"; do
    if ! mountpoint -q "$mnt"; then
      unit="$(systemd-escape --path --suffix=mount "$mnt")"
      echo "ERROR: $mnt is not a mountpoint. Refusing to start." >&2
      echo "       Recover with:" >&2
      echo "         sudo systemctl reset-failed $unit" >&2
      echo "         sudo mount -a" >&2
      echo "         findmnt $mnt" >&2
      exit 1
    fi
  done
}

up() {
  require_mounts
  for stack in "${STACKS[@]}"; do
    echo ">>> Starting $stack"
    (cd "$stack" && docker compose up -d)
  done
}

down() {
  for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
    stack="${STACKS[i]}"
    echo ">>> Stopping $stack"
    (cd "$stack" && docker compose down)
  done
}

status() {
  for stack in "${STACKS[@]}"; do
    echo "=== $stack ==="
    (cd "$stack" && docker compose ps)
    echo
  done
}

case "${1:-}" in
  up)      up ;;
  down)    down ;;
  restart) down; up ;;
  status)  status ;;
  *)
    echo "Usage: $0 {up|down|restart|status}" >&2
    exit 1
    ;;
esac
