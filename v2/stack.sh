#!/usr/bin/env bash
# Manage the v2 homelab stacks.
#
# Usage:
#   ./stack.sh up        Start all stacks in dependency order
#   ./stack.sh down      Stop all stacks in reverse order
#   ./stack.sh restart   Down then up
#   ./stack.sh status    Show running containers per stack

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

up() {
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
