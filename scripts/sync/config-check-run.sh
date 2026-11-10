#!/usr/bin/env bash
# Scheduled runner for the shared-config drift check (systemd/claude-config-check.timer).
#
#   config-check-run.sh [shared-dir]     shared-dir defaults to $CLAUDE_SHARED_DIR
#
# Runs `sync-claude-config.sh --check` and appends its output to a dated log that ends
# with "=== run finished rc=N at <iso> ===", for anything that watches logs. Exits with
# the check's status, so systemd marks the unit failed when the config has drifted.
# It only reports: fixing drift is a deliberate `sync-claude-config.sh` run.
#
# Log folder: $CLAUDE_CHECK_LOG_DIR, else ~/.local/state/claude-config-check.
set -uo pipefail

SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${1:-${CLAUDE_SHARED_DIR:-}}"
LOG_DIR="${CLAUDE_CHECK_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-config-check}"
LOG="$LOG_DIR/check-$(date +%Y%m%d).log"

mkdir -p "$LOG_DIR"

{
    echo "=== run started at $(date -Is) ==="
    # A stale checkout would report "in sync" against an old shared layer, so look at
    # the remote first. Being offline is a warning, not drift.
    if [ -n "$SHARED_DIR" ] && git -C "$SHARED_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$SHARED_DIR" fetch --quiet 2>&1 || echo "warning: fetch failed — checking against the local checkout"
        if [ -n "$(git -C "$SHARED_DIR" log --oneline 'HEAD..@{u}' 2>/dev/null)" ]; then
            echo "note: the shared-config repo is behind its remote — run 'git pull' then re-sync"
        fi
    fi
    bash "$SYNC_DIR/sync-claude-config.sh" --check ${SHARED_DIR:+"$SHARED_DIR"} 2>&1
    rc=$?
    echo "=== run finished rc=$rc at $(date -Is) ==="
} >> "$LOG" 2>&1

exit "$rc"
