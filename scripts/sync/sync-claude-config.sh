#!/usr/bin/env bash
# Sync a shared Claude Code config layer (a directory you keep in git) into ~/.claude.
#
#   sync-claude-config.sh [shared-dir]            apply  — merge shared layer into ~/.claude
#   sync-claude-config.sh --check [shared-dir]    report drift, exit 1 if any (no writes)
#
# Exit 2 means it could not run at all (no jq, no shared dir, a shared file missing),
# so a scheduler can tell that apart from drift.
#   sync-claude-config.sh --dry-run [shared-dir]  show what apply would change, no writes
#
# shared-dir defaults to $CLAUDE_SHARED_DIR. It holds GLOBAL-PREFS.md,
# settings.shared.json, and mcp.shared.json, and optionally skills/, agents/, mods/,
# and statusline-command.sh. templates/claude-shared/ is a starting point.
# See scripts/sync/README.md.
#
# What it touches, and nothing else:
#   ~/.claude/CLAUDE.md      — ensures one @-import line pointing at <shared-dir>/GLOBAL-PREFS.md
#   ~/.claude/settings.json  — unions in the shared permission/autoMode lists, subtracts
#                              retiredAllows, merges shared object keys (modelSettings,
#                              enabledPlugins, env) shared-wins per entry, points
#                              env.CLAUDE_CODE_PLUGIN_DIRS at <shared-dir>/mods; sets statusLine if unset
#   ~/.claude/{skills,agents,mods}/<name> — one-way mirror, repo wins
#   ~/.claude/statusline-command.sh — copied from <shared-dir>, repo wins
#   ~/.claude.json mcpServers — shared servers from <shared-dir>/mcp.shared.json added or updated;
#                              a server's local env values are kept (that is where tokens live)
#   plugins                  — every plugin enabled in the shared layer is installed if missing
#
# Machine-specific settings (hooks, model, effortLevel, minimumVersion, OS-path
# permissions, extra MCP servers) are never removed or overwritten. The merge is
# additive: shared entries are added if missing, local extras are kept.
set -euo pipefail

# Under Git Bash/MSYS, `pwd` yields /c/Users/... which Claude Code cannot resolve in an
# @-import; `pwd -W` yields the native C:/Users/... form. Harmless no-op elsewhere.
native_pwd() { pwd -W 2>/dev/null || pwd; }

mode=apply
case "${1:-}" in
    --check)   mode=check; shift ;;
    --dry-run) mode=dry; shift ;;
    -*) echo "usage: $(basename "$0") [--check|--dry-run] [shared-dir]" >&2; exit 2 ;;
esac
SHARED_ARG="${1:-${CLAUDE_SHARED_DIR:-}}"
if [ -z "$SHARED_ARG" ] || [ ! -d "$SHARED_ARG" ]; then
    echo "usage: $(basename "$0") [--check|--dry-run] [shared-dir]" >&2
    echo "shared-dir (or CLAUDE_SHARED_DIR) must be an existing directory${SHARED_ARG:+, got: $SHARED_ARG}" >&2
    exit 2
fi

SHARED_DIR="$(cd "$SHARED_ARG" && native_pwd)"
SHARED_PREFS="$SHARED_DIR/GLOBAL-PREFS.md"
SHARED_SETTINGS="$SHARED_DIR/settings.shared.json"
SHARED_MCP="$SHARED_DIR/mcp.shared.json"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GLOBAL_MD="$CLAUDE_DIR/CLAUDE.md"
SETTINGS="$CLAUDE_DIR/settings.json"
# ~/.claude.json sits beside ~/.claude, or inside CLAUDE_CONFIG_DIR when that is set
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then CLAUDE_JSON="$CLAUDE_DIR/.claude.json"; else CLAUDE_JSON="$HOME/.claude.json"; fi
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1; PATH_SEP=';' ;; *) ON_WINDOWS=0; PATH_SEP=':' ;; esac

IMPORT_LINE="@$SHARED_PREFS"
IMPORT_BLOCK="## Shared preferences

$IMPORT_LINE"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[ -f "$SHARED_PREFS" ]    || { echo "missing $SHARED_PREFS" >&2; exit 2; }
[ -f "$SHARED_SETTINGS" ] || { echo "missing $SHARED_SETTINGS" >&2; exit 2; }
[ -f "$SHARED_MCP" ]      || { echo "missing $SHARED_MCP" >&2; exit 2; }

drift=0
note() { echo "  $*"; }

# --- 1. the @-import in the per-machine global CLAUDE.md -----------------------
# Matched on the resolved path, so a machine that keeps the repo elsewhere still
# gets exactly one import line rather than a duplicate.
if [ -f "$GLOBAL_MD" ] && grep -qxF "$IMPORT_LINE" "$GLOBAL_MD"; then
    note "CLAUDE.md: import present"
else
    drift=1
    note "CLAUDE.md: import MISSING -> $IMPORT_LINE"
    if [ "$mode" = apply ]; then
        [ -f "$GLOBAL_MD" ] || : > "$GLOBAL_MD"
        printf '\n%s\n' "$IMPORT_BLOCK" >> "$GLOBAL_MD"
        note "CLAUDE.md: import appended"
    fi
fi

# --- 2. settings.json merge ---------------------------------------------------
# A missing file reads as {}; only apply writes one.
current_settings="$(cat "$SETTINGS" 2>/dev/null || echo '{}')"

# Every directory under <shared-dir>/mods/ is one plugin, loaded the way --plugin-dir loads it.
# Written with a leading ~ so the same value works on both machines.
plugin_dirs=""
for d in "$SHARED_DIR"/mods/*/; do
    [ -d "$d" ] || continue
    plugin_dirs="${plugin_dirs:+$plugin_dirs$PATH_SEP}~/.claude/mods/$(basename "$d")"
done

merged="$(jq --slurpfile shared "$SHARED_SETTINGS" --arg plugin_dirs "$plugin_dirs" '
    def dedup: reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end);
    # shared entries first, then whatever this machine has added on top
    def union($a; $b): (($a // []) + ($b // [])) | dedup;
    # keys with their own merge rule below, or that never reach settings.json
    def special: IN("permissions", "autoMode", "statusLine", "retiredAllows");

    . as $l | ($shared[0]) as $s
    | $l
    # shared scalar preferences: shared is the source of truth
    | reduce ($s | to_entries[] | select((.value | type) != "object" and (.key | special | not))) as $e (.; .[$e.key] = $e.value)
    # shared objects (modelSettings, enabledPlugins, env): shared wins per entry, local extras kept
    | reduce ($s | to_entries[] | select((.value | type) == "object" and (.key | special | not))) as $e (.; .[$e.key] = ((.[$e.key] // {}) * $e.value))
    | if $plugin_dirs != "" then .env.CLAUDE_CODE_PLUGIN_DIRS = $plugin_dirs else . end
    | .permissions.allow    = (union($s.permissions.allow;    $l.permissions.allow) - ($s.retiredAllows // []))
    | if ($s.permissions.deny // []) != [] then .permissions.deny = union($s.permissions.deny; $l.permissions.deny) else . end
    | if $s.autoMode.allow     then .autoMode.allow     = union($s.autoMode.allow;     $l.autoMode.allow)     else . end
    | if $s.autoMode.soft_deny then .autoMode.soft_deny = union($s.autoMode.soft_deny; $l.autoMode.soft_deny) else . end
    # status line: shared default, but a machine that set its own keeps it
    | if ($l.statusLine // $s.statusLine) then .statusLine = ($l.statusLine // $s.statusLine) else . end
' <<<"$current_settings")"

if [ "$(jq -S . <<<"$current_settings")" = "$(jq -S . <<<"$merged")" ]; then
    note "settings.json: in sync"
else
    drift=1
    note "settings.json: drift —"
    diff <(jq -S . <<<"$current_settings") <(jq -S . <<<"$merged") | sed 's/^/    /' || true
    if [ "$mode" = apply ]; then
        if [ -f "$SETTINGS" ]; then
            cp "$SETTINGS" "$SETTINGS.bak"
            note "settings.json: merged (previous saved to settings.json.bak)"
        else
            note "settings.json: created"
        fi
        jq . <<<"$merged" > "$SETTINGS"
    fi
fi

# --- 3. user-content directories (skills, agents) -----------------------------
# One-way mirror, repo -> machine, per top-level entry. Additive and update-only: a
# tracked entry is copied over if it differs, but an entry that exists only on this
# machine is never deleted — it is reported so it can be promoted into the repo.
# Authoring happens in the repo; edits made directly in ~/.claude are overwritten.
sync_dir() {
    local kind="$1"
    local src="$SHARED_DIR/$kind"
    local dest="$CLAUDE_DIR/$kind"
    [ -d "$src" ] || return 0

    local entry name
    for entry in "$src"/*; do
        [ -e "$entry" ] || continue          # empty dir
        name="$(basename "$entry")"
        if [ -e "$dest/$name" ] && diff -rq "$entry" "$dest/$name" >/dev/null 2>&1; then
            note "$kind/$name: in sync"
            continue
        fi
        drift=1
        if [ -e "$dest/$name" ]; then
            note "$kind/$name: DIFFERS from tracked copy"
        else
            note "$kind/$name: MISSING"
        fi
        if [ "$mode" = apply ]; then
            mkdir -p "$dest"
            rm -rf "$dest/$name"
            cp -R "$entry" "$dest/$name"
            note "$kind/$name: installed"
        fi
    done

    # machine-only entries — reported, never touched
    [ -d "$dest" ] || return 0
    for entry in "$dest"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        [ -e "$src/$name" ] || note "$kind/$name: untracked (local only — promote it into $SHARED_DIR/$kind/ to share)"
    done
}

sync_dir skills
sync_dir agents
sync_dir mods

# --- 4. single files (status line script) -------------------------------------
sync_file() {
    local name="$1"
    local src="$SHARED_DIR/$name"
    local dest="$CLAUDE_DIR/$name"
    [ -f "$src" ] || return 0
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        note "$name: in sync"; return 0
    fi
    drift=1
    [ -f "$dest" ] && note "$name: DIFFERS from tracked copy" || note "$name: MISSING"
    if [ "$mode" = apply ]; then
        cp "$src" "$dest"
        note "$name: installed"
    fi
}

sync_file statusline-command.sh

# --- 5. MCP servers in ~/.claude.json ------------------------------------------
# Shared servers are added or updated (shared wins for type/command/args/url). A server's
# existing env values on this machine are kept, since that is where tokens live, and
# servers only this machine has are never touched. Nothing from this file is printed:
# the diff would expose tokens.
current_claude_json="$(cat "$CLAUDE_JSON" 2>/dev/null || echo '{}')"
mcp_merged="$(jq --slurpfile shared "$SHARED_MCP" --argjson win "$ON_WINDOWS" '
    . as $l
    | reduce ($shared[0].mcpServers | to_entries[]) as $e (.;
        .mcpServers[$e.key] = (
            ($l.mcpServers[$e.key] // {}) as $cur
            | $e.value
            | .env = ((.env // {}) + ($cur.env // {}) | with_entries(select(.value != "")))
            | if $win == 1 and .type == "stdio" and .command == "npx"
              then .command = "cmd" | .args = ["/c", "npx"] + .args else . end
            | if (.env | length) == 0 then del(.env) else . end))
' <<<"$current_claude_json")"
mcp_drift=0
for name in $(jq -r '.mcpServers | keys[]' "$SHARED_MCP"); do
    if [ "$(jq -S --arg n "$name" '.mcpServers[$n]' <<<"$current_claude_json")" = "$(jq -S --arg n "$name" '.mcpServers[$n]' <<<"$mcp_merged")" ]; then
        note "mcp/$name: in sync"
    else
        mcp_drift=1; drift=1
        [ "$(jq --arg n "$name" '.mcpServers[$n]' <<<"$current_claude_json")" = null ] && note "mcp/$name: MISSING" || note "mcp/$name: DIFFERS from shared definition"
    fi
done
if [ "$mcp_drift" -eq 1 ] && [ "$mode" = apply ]; then
    if [ -f "$CLAUDE_JSON" ]; then
        cp "$CLAUDE_JSON" "$CLAUDE_JSON.bak"
        note "mcp: merged (previous saved to $(basename "$CLAUDE_JSON").bak)"
    else
        note "mcp: created $(basename "$CLAUDE_JSON")"
    fi
    jq . <<<"$mcp_merged" > "$CLAUDE_JSON"
fi

# --- 6. plugins ----------------------------------------------------------------
# enabledPlugins only switches an installed plugin on; it does not install it.
installed="$CLAUDE_DIR/plugins/installed_plugins.json"
for plugin in $(jq -r '.enabledPlugins // {} | to_entries[] | select(.value) | .key' "$SHARED_SETTINGS"); do
    if [ -f "$installed" ] && jq -e --arg p "$plugin" '.plugins[$p]' "$installed" >/dev/null; then
        note "plugin/$plugin: installed"; continue
    fi
    drift=1
    note "plugin/$plugin: NOT INSTALLED"
    if [ "$mode" = apply ]; then
        if command -v claude >/dev/null; then
            claude plugin install "$plugin" --scope user -y >/dev/null && note "plugin/$plugin: installed" \
                || note "plugin/$plugin: install FAILED (run: claude plugin install $plugin --scope user)"
        else
            note "plugin/$plugin: claude not on PATH, install by hand"
        fi
    fi
done

case "$mode" in
    check) [ "$drift" -eq 0 ] || { echo "shared Claude config is out of sync — run $(basename "$0")" >&2; exit 1; }
           echo "shared Claude config in sync" ;;
    dry)   [ "$drift" -eq 0 ] && echo "nothing to do" || echo "run without --dry-run to apply" ;;
    apply) echo "shared Claude config applied" ;;
esac
