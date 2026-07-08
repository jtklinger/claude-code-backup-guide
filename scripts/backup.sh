#!/bin/bash

# Claude Code Settings Backup Script
#
# Config-driven backup of all Claude Code data categories.
# Reads backup-config.json from the repo root and backs up
# settings, MCP config, skills, plugins, user-content dirs
# (plans, commands, agents, output-styles, rules, hooks,
# scheduled-tasks), todos, and per-project data including
# subagent transcripts and tool-result payloads.
#
# Usage: bash backup.sh [backup-directory] [--fast] [--status] [--sanitize <output-directory>]
#
#   --fast   Detect changes by size + mtime instead of a full byte compare.
#            Much faster over large, mostly-unchanged data (session transcripts).
#            See is_unchanged() for the trade-off. Default is byte-exact (cmp).
#   --status Print a health readout (last commit, remote sync, repo + .git size)
#            for the backup directory and exit without backing up.
#
# Fully non-interactive — safe for cron.

set -e

SCRIPT_VERSION="2.5.0"

# Associative arrays (per-category counters + the project-dedup `seen` map) require
# bash 4+. Stock macOS ships bash 3.2, where `declare -A` fails at runtime. Check up
# front and give a clear, actionable message instead of a cryptic error mid-run.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: this script requires bash 4.0+ (found ${BASH_VERSION:-non-bash shell})." >&2
    echo "On macOS: 'brew install bash', then run with the newer bash (e.g. /opt/homebrew/bin/bash)." >&2
    exit 1
fi

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global state
FAST_COMPARE=false   # --fast: size+mtime change detection instead of byte-exact cmp
STATUS_MODE=false    # --status: print a health readout and exit
COUNTS_GLOBAL=0
COUNTS_MCP=0
COUNTS_SKILLS=0
COUNTS_PLUGINS=0
COUNTS_PLUGIN_DATA=0
COUNTS_TODOS=0
COUNTS_PROJECTS=0
declare -A USER_CONTENT_COUNTS

# User-content directories backed up via a generic loop.
# Format: "<dir-name>:<file-glob>" — glob filters which files to sync.
# Add new categories here as Claude Code introduces them.
USER_CONTENT_DIRS=(
    "plans:*.md"
    "commands:*.md"
    "agents:*"
    "output-styles:*"
    "rules:*"
    "hooks:*"
    "scheduled-tasks:*"
)

# Timestamp for log lines
log_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    echo -e "[$(log_ts)] ${GREEN}$1${NC}"
}

log_warn() {
    echo -e "[$(log_ts)] ${YELLOW}$1${NC}"
}

log_error() {
    echo -e "[$(log_ts)] ${RED}$1${NC}"
}

# ─── Helper Functions ───────────────────────────────────────────────

parse_config() {
    local config_file="$BACKUP_DIR/backup-config.json"

    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Please install jq first."
        exit 1
    fi

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        log_error "Run init.sh first to create backup-config.json"
        exit 1
    fi

    local version
    version=$(jq -r '.version // empty' "$config_file")
    if [ "$version" != "1" ]; then
        log_error "Unsupported config version: ${version:-missing}. Expected version 1."
        exit 1
    fi

    # Read config values (strip \r for Windows compatibility)
    CLAUDE_DIR=$(jq -r '.claude_dir // "~/.claude"' "$config_file" | tr -d '\r')
    INCLUDE_SESSIONS=$(jq -r '.include_sessions // true' "$config_file" | tr -d '\r')
    INCLUDE_TODOS=$(jq -r '.include_todos // true' "$config_file" | tr -d '\r')
    GIT_AUTO_PUSH=$(jq -r '.git_auto_push // false' "$config_file" | tr -d '\r')
    GIT_REMOTE=$(jq -r '.git_remote // "origin"' "$config_file" | tr -d '\r')
    GIT_BRANCH=$(jq -r '.git_branch // "main"' "$config_file" | tr -d '\r')

    # Expand ~ to $HOME in claude_dir
    CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

    # Read the projects array: each entry is an exact project slug, a glob
    # pattern (e.g. "C--Users-me-projects-Homelab*" to catch a project and
    # all its worktree sessions), or "*" alone for full dynamic discovery.
    # An empty array means "back up no project/session data" (opt-out, kept
    # for anyone who intentionally excludes session history).
    local -a project_patterns=()
    while IFS= read -r proj; do
        proj="${proj%$'\r'}"  # Strip Windows carriage return
        [ -n "$proj" ] && project_patterns+=("$proj")
    done < <(jq -r '(.projects // ["*"])[]?' "$config_file")

    PROJECTS=()
    if [ ${#project_patterns[@]} -gt 0 ] && [ -d "$CLAUDE_DIR/projects" ]; then
        local -A seen=()
        local pattern matched dir name saved_ifs
        local -a matches
        for pattern in "${project_patterns[@]}"; do
            matched=false
            # Expand the glob with word-splitting disabled so a pattern that
            # contains a space is treated as one literal token, never split into
            # args that would glob against the current working directory.
            shopt -s nullglob
            saved_ifs=$IFS; IFS=
            matches=( "$CLAUDE_DIR/projects/"$pattern )
            IFS=$saved_ifs
            shopt -u nullglob
            for dir in "${matches[@]}"; do
                [ -d "$dir" ] || continue
                name=$(basename "$dir")
                if [ -z "${seen[$name]:-}" ]; then
                    PROJECTS+=("$name")
                    seen[$name]=1
                fi
                matched=true
            done
            # Literal (non-glob) entries that don't exist yet are kept as-is
            # so backup_projects() can still warn "not found" instead of the
            # entry silently vanishing.
            if [ "$matched" = false ] && [[ "$pattern" != *'*'* ]] && [ -z "${seen[$pattern]:-}" ]; then
                PROJECTS+=("$pattern")
                seen[$pattern]=1
            fi
        done
    fi

    log_info "Config loaded: claude_dir=$CLAUDE_DIR, ${#PROJECTS[@]} project(s)"
}

# is_unchanged <src> <dest> — 0 (skip, up to date) / 1 (must copy).
#   Default: byte-exact compare (cmp -s). Always correct; reads every byte.
#   --fast:  compare size + mtime only — ONE stat call covering BOTH files, zero
#            byte reads. cmp reads both files end-to-end; this reads neither, so
#            it is strictly cheaper per file over a large, mostly-unchanged corpus
#            (session transcripts). Trade-off: a content change that preserves
#            BOTH size and mtime is missed. Claude's session/todo files are
#            append-only (size+mtime move with content), so this is safe in
#            practice; the default stays byte-exact. GNU stat first (Linux +
#            Windows Git Bash), BSD stat fallback (macOS).
is_unchanged() {
    local src="$1" dest="$2"
    [ -f "$dest" ] || return 1
    if [ "$FAST_COMPARE" = "true" ]; then
        local meta m1 m2
        meta=$(stat -c '%s:%Y' "$src" "$dest" 2>/dev/null) \
            || meta=$(stat -f '%z:%m' "$src" "$dest" 2>/dev/null)
        { read -r m1; read -r m2; } <<< "$meta"
        [ -n "$m1" ] && [ "$m1" = "$m2" ]
        return
    fi
    cmp -s "$src" "$dest"
}

# copy_file <src> <dest> — copy honoring the active mode. In --fast mode preserve
# mtime (cp -p) so an unchanged file's mtime still matches its source on the NEXT
# run and the fast skip-check stays stable. Plain cp would stamp "now", making
# every file look changed each run and defeating the optimization.
copy_file() {
    if [ "$FAST_COMPARE" = "true" ]; then cp -p "$1" "$2"; else cp "$1" "$2"; fi
}

copy_if_changed() {
    local source="$1"
    local dest="$2"

    if [ ! -e "$source" ]; then
        log_warn "Source not found, skipping: $source"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"

    if is_unchanged "$source" "$dest"; then
        return 0
    fi

    copy_file "$source" "$dest"
    return 0
}

sync_directory() {
    local source_dir="$1"
    local dest_dir="$2"
    local file_glob="${3:-*}"
    local copied=0

    if [ ! -d "$source_dir" ]; then
        return 0
    fi

    mkdir -p "$dest_dir"

    # Copy new/changed files
    local found_files=false
    while IFS= read -r -d '' src_file; do
        found_files=true
        local rel_path="${src_file#"$source_dir"/}"
        local dest_file="$dest_dir/$rel_path"
        mkdir -p "$(dirname "$dest_file")"
        if ! is_unchanged "$src_file" "$dest_file"; then
            copy_file "$src_file" "$dest_file"
            ((copied++)) || true
        fi
    done < <(find "$source_dir" -type f -name "$file_glob" -print0 2>/dev/null)

    # Remove stale files from dest that no longer exist in source
    if [ -d "$dest_dir" ]; then
        while IFS= read -r -d '' dest_file; do
            local rel_path="${dest_file#"$dest_dir"/}"
            local src_file="$source_dir/$rel_path"
            if [ ! -f "$src_file" ]; then
                rm -f "$dest_file"
            fi
        done < <(find "$dest_dir" -type f -name "$file_glob" -print0 2>/dev/null)
    fi

    echo "$copied"
}

# ─── Backup Functions ───────────────────────────────────────────────

backup_global_settings() {
    log_info "Backing up global settings..."
    local count=0
    local dest_dir="$BACKUP_DIR/global"
    mkdir -p "$dest_dir"

    # Back up all *.md files from claude_dir (CLAUDE.md, HOMELAB-CONTEXT.md, etc.)
    if ls "$CLAUDE_DIR"/*.md &>/dev/null; then
        for md_file in "$CLAUDE_DIR"/*.md; do
            local basename
            basename=$(basename "$md_file")
            copy_if_changed "$md_file" "$dest_dir/$basename"
            ((count++)) || true
        done
    fi

    # Back up custom root scripts (MCP helpers, unlock scripts, migration tools, etc.)
    # Captures *.cmd, *.ps1, *.js, *.sh, *.py — anything a user might drop in ~/.claude/
    for ext in cmd ps1 js sh py; do
        if ls "$CLAUDE_DIR"/*."$ext" &>/dev/null; then
            for script_file in "$CLAUDE_DIR"/*."$ext"; do
                local basename
                basename=$(basename "$script_file")
                copy_if_changed "$script_file" "$dest_dir/$basename"
                ((count++)) || true
            done
        fi
    done

    # Specific JSON config files
    for f in settings.json settings.local.json keybindings.json; do
        if [ -f "$CLAUDE_DIR/$f" ]; then
            copy_if_changed "$CLAUDE_DIR/$f" "$dest_dir/$f"
            ((count++)) || true
        fi
    done

    # Remove stale root files from dest that no longer exist in source
    # (covers *.md and the script extensions above)
    for dest_file in "$dest_dir"/*; do
        [ -f "$dest_file" ] || continue
        # Skip the specific JSON configs — those have their own lifecycle
        local bname
        bname=$(basename "$dest_file")
        case "$bname" in
            settings.json|settings.local.json|keybindings.json|claude.json) continue ;;
        esac
        if [ ! -f "$CLAUDE_DIR/$bname" ]; then
            rm -f "$dest_file"
        fi
    done

    COUNTS_GLOBAL=$count
    log_info "  Global settings: $count file(s) processed"
}

backup_mcp_config() {
    log_info "Backing up MCP config..."
    local count=0
    local dest_dir="$BACKUP_DIR/global"
    mkdir -p "$dest_dir"

    # ~/.claude.json lives in HOME, not inside ~/.claude/
    if [ -f "$HOME/.claude.json" ]; then
        copy_if_changed "$HOME/.claude.json" "$dest_dir/claude.json"
        ((count++)) || true
    else
        log_warn "  ~/.claude.json not found (no MCP config to back up)"
    fi

    COUNTS_MCP=$count
    log_info "  MCP config: $count file(s) processed"
}

backup_skills() {
    log_info "Backing up skills..."
    local source_dir="$CLAUDE_DIR/skills"
    local dest_dir="$BACKUP_DIR/skills"

    if [ ! -d "$source_dir" ]; then
        log_warn "  Skills directory not found, skipping"
        return 0
    fi

    # Prefer rsync if available (excludes .git, handles deletes)
    if command -v rsync &>/dev/null; then
        rsync -a --delete --exclude='.git' "$source_dir/" "$dest_dir/" >/dev/null 2>&1 || true
    else
        # Manual sync fallback — copy all files excluding .git
        mkdir -p "$dest_dir"
        local copied=0
        while IFS= read -r -d '' src_file; do
            local rel_path="${src_file#"$source_dir"/}"
            local dest_file="$dest_dir/$rel_path"
            mkdir -p "$(dirname "$dest_file")"
            if ! is_unchanged "$src_file" "$dest_file"; then
                copy_file "$src_file" "$dest_file"
                ((copied++)) || true
            fi
        done < <(find "$source_dir" -type f -not -path '*/.git/*' -print0 2>/dev/null)

        # Remove stale files
        if [ -d "$dest_dir" ]; then
            while IFS= read -r -d '' dest_file; do
                local rel_path="${dest_file#"$dest_dir"/}"
                if [ ! -f "$source_dir/$rel_path" ]; then
                    rm -f "$dest_file"
                fi
            done < <(find "$dest_dir" -type f -not -path '*/.git/*' -print0 2>/dev/null)
        fi
    fi

    local file_count=0
    if [ -d "$dest_dir" ]; then
        file_count=$(find "$dest_dir" -type f 2>/dev/null | wc -l)
    fi
    COUNTS_SKILLS=$file_count
    log_info "  Skills: $file_count file(s)"
}

backup_plugins() {
    log_info "Backing up plugins..."
    local count=0
    local source_dir="$CLAUDE_DIR/plugins"
    local dest_dir="$BACKUP_DIR/plugins"

    if [ ! -d "$source_dir" ]; then
        log_warn "  Plugins directory not found, skipping"
        return 0
    fi

    mkdir -p "$dest_dir"

    # Only back up specific config files, NOT cache/ or marketplaces/
    for f in installed_plugins.json blocklist.json known_marketplaces.json; do
        if [ -f "$source_dir/$f" ]; then
            copy_if_changed "$source_dir/$f" "$dest_dir/$f"
            ((count++)) || true
        fi
    done

    COUNTS_PLUGINS=$count
    log_info "  Plugins: $count file(s) processed"
}

backup_plugin_data() {
    log_info "Backing up plugin data..."
    local source_dir="$CLAUDE_DIR/plugins/data"
    local dest_dir="$BACKUP_DIR/plugins/data"

    if [ ! -d "$source_dir" ]; then
        log_info "  Plugin data directory not found, skipping"
        COUNTS_PLUGIN_DATA=0
        return 0
    fi

    # Size guard: warn if plugin data exceeds 50 MB
    local data_size_kb
    data_size_kb=$(du -sk "$source_dir" 2>/dev/null | cut -f1)
    if [ "${data_size_kb:-0}" -gt 51200 ]; then
        log_warn "  Plugin data is $(( data_size_kb / 1024 )) MB — backing up anyway (set plugin_data_max_mb in config to skip large dirs)"
    fi

    if command -v rsync &>/dev/null; then
        rsync -a --delete "$source_dir/" "$dest_dir/" >/dev/null 2>&1 || true
    else
        mkdir -p "$dest_dir"
        while IFS= read -r -d '' src_file; do
            local rel_path="${src_file#"$source_dir"/}"
            local dest_file="$dest_dir/$rel_path"
            mkdir -p "$(dirname "$dest_file")"
            if ! is_unchanged "$src_file" "$dest_file"; then
                copy_file "$src_file" "$dest_file"
            fi
        done < <(find "$source_dir" -type f -print0 2>/dev/null)

        # Remove stale files
        if [ -d "$dest_dir" ]; then
            while IFS= read -r -d '' dest_file; do
                local rel_path="${dest_file#"$dest_dir"/}"
                if [ ! -f "$source_dir/$rel_path" ]; then
                    rm -f "$dest_file"
                fi
            done < <(find "$dest_dir" -type f -print0 2>/dev/null)
        fi
    fi

    COUNTS_PLUGIN_DATA=$(find "$dest_dir" -type f 2>/dev/null | wc -l)
    log_info "  Plugin data: $COUNTS_PLUGIN_DATA file(s)"
}

backup_user_content() {
    log_info "Backing up user content directories..."

    for entry in "${USER_CONTENT_DIRS[@]}"; do
        local name="${entry%%:*}"
        local glob="${entry#*:}"
        local source_dir="$CLAUDE_DIR/$name"
        local dest_dir="$BACKUP_DIR/$name"

        if [ ! -d "$source_dir" ]; then
            continue
        fi

        sync_directory "$source_dir" "$dest_dir" "$glob" >/dev/null

        local count=0
        if [ -d "$dest_dir" ]; then
            count=$(find "$dest_dir" -type f -name "$glob" 2>/dev/null | wc -l)
        fi
        USER_CONTENT_COUNTS["$name"]=$count
        log_info "  $name: $count file(s)"
    done
}

backup_todos() {
    if [ "$INCLUDE_TODOS" != "true" ]; then
        log_info "Skipping todos (disabled in config)"
        return 0
    fi

    log_info "Backing up todos..."
    local source_dir="$CLAUDE_DIR/todos"
    local dest_dir="$BACKUP_DIR/todos"

    if [ ! -d "$source_dir" ]; then
        log_warn "  Todos directory not found, skipping"
        return 0
    fi

    local count
    count=$(sync_directory "$source_dir" "$dest_dir" "*.json")
    COUNTS_TODOS=$(find "$dest_dir" -type f -name "*.json" 2>/dev/null | wc -l)
    log_info "  Todos: $COUNTS_TODOS file(s)"
}

backup_projects() {
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        log_info "No projects configured, skipping project backup"
        return 0
    fi

    log_info "Backing up ${#PROJECTS[@]} project(s)..."
    local total_count=0

    for project in "${PROJECTS[@]}"; do
        local source_dir="$CLAUDE_DIR/projects/$project"
        local dest_base="$BACKUP_DIR/projects/$project"

        if [ ! -d "$source_dir" ]; then
            log_warn "  Project not found, skipping: $project"
            continue
        fi

        log_info "  Project: $project"

        # Copy memory files
        if [ -d "$source_dir/memory" ]; then
            sync_directory "$source_dir/memory" "$dest_base/memory" >/dev/null
            local mem_files
            mem_files=$(find "$dest_base/memory" -type f 2>/dev/null | wc -l)
            ((total_count += mem_files)) || true
            log_info "    Memory: $mem_files file(s)"
        fi

        # Copy session files if enabled
        if [ "$INCLUDE_SESSIONS" = "true" ]; then
            local sessions_dest="$dest_base/sessions"
            mkdir -p "$sessions_dest"

            local session_count=0
            # Copy *.jsonl files
            if ls "$source_dir"/*.jsonl &>/dev/null; then
                for src_file in "$source_dir"/*.jsonl; do
                    local basename
                    basename=$(basename "$src_file")
                    copy_if_changed "$src_file" "$sessions_dest/$basename"
                    ((session_count++)) || true
                done
            fi

            # Copy *.meta.json files alongside sessions
            if ls "$source_dir"/*.meta.json &>/dev/null; then
                for src_file in "$source_dir"/*.meta.json; do
                    local basename
                    basename=$(basename "$src_file")
                    copy_if_changed "$src_file" "$sessions_dest/$basename"
                    ((session_count++)) || true
                done
            fi

            # Remove stale session files
            if [ -d "$sessions_dest" ]; then
                while IFS= read -r -d '' dest_file; do
                    local basename
                    basename=$(basename "$dest_file")
                    if [ ! -f "$source_dir/$basename" ]; then
                        rm -f "$dest_file"
                    fi
                done < <(find "$sessions_dest" -type f \( -name "*.jsonl" -o -name "*.meta.json" \) -print0 2>/dev/null)
            fi

            ((total_count += session_count)) || true
            log_info "    Sessions: $session_count file(s)"
        fi

        # Copy per-session nested data: <session-uuid>/subagents/ and <session-uuid>/tool-results/
        # Claude Code stores subagent transcripts and tool-result payloads inside a
        # subdirectory named after the parent session UUID.
        for category in subagents tool-results; do
            local category_count=0
            local category_dest="$dest_base/$category"

            for session_dir in "$source_dir"/*/; do
                [ -d "$session_dir" ] || continue
                local uuid
                uuid=$(basename "$session_dir")
                # Skip the memory/ dir which is handled separately
                [ "$uuid" = "memory" ] && continue

                local src_category="$session_dir$category"
                [ -d "$src_category" ] || continue

                local dest_uuid="$category_dest/$uuid"
                sync_directory "$src_category" "$dest_uuid" "*" >/dev/null

                local uuid_count=0
                if [ -d "$dest_uuid" ]; then
                    uuid_count=$(find "$dest_uuid" -type f 2>/dev/null | wc -l)
                fi
                ((category_count += uuid_count)) || true
            done

            # Remove stale <uuid>/ subdirectories for sessions that no longer exist in source
            if [ -d "$category_dest" ]; then
                for uuid_dir in "$category_dest"/*/; do
                    [ -d "$uuid_dir" ] || continue
                    local uuid
                    uuid=$(basename "$uuid_dir")
                    if [ ! -d "$source_dir/$uuid/$category" ]; then
                        rm -rf "$uuid_dir"
                    fi
                done
            fi

            if [ "$category_count" -gt 0 ]; then
                log_info "    ${category}: $category_count file(s)"
                ((total_count += category_count)) || true
            fi
        done
    done

    COUNTS_PROJECTS=$total_count
    log_info "  Projects total: $total_count file(s)"
}

# ─── Sanitize/Export Functions ─────────────────────────────────────

sanitize_claude_json() {
    local src="$BACKUP_DIR/global/claude.json"
    local dest="$SANITIZE_DIR/global/claude.json"

    if [ ! -f "$src" ]; then
        log_warn "  No claude.json in backup, skipping MCP sanitization"
        return 0
    fi

    mkdir -p "$SANITIZE_DIR/global"

    # Write jq filter to temp file (avoids Windows shell quoting issues)
    local jq_tmp
    jq_tmp=$(mktemp)
    cat > "$jq_tmp" << 'JQFILTER'
{
    mcpServers: (
        .mcpServers // {} | to_entries | map({
            key: .key,
            value: ({
                type: .value.type,
                command: (if (.value.command | test("^(/|[A-Z]:[/\\\\\\\\]|~/)")) then "<PATH>" else .value.command end),
                args: (
                    .value.args // [] | map(
                        if (. == "/c" or . == "/C") then .
                        elif startswith("--host=") then "--host=<HOSTNAME>"
                        elif startswith("--user=") then "--user=<USERNAME>"
                        elif startswith("--key=") then "--key=<SSH_KEY_PATH>"
                        elif startswith("--header=") then
                            (if (ltrimstr("--header=") | test("(authorization|bearer)"; "i")) then "--header=<AUTH_TOKEN>" else . end)
                        elif startswith("--header") then .
                        elif test("^(authorization:|bearer )"; "i") then "<AUTH_TOKEN>"
                        elif test("^https?://") then "<URL>"
                        elif test("\\\\.(com|local|net|org|io)([:/]|$)") then "<HOSTNAME>"
                        elif test("^[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.[0-9]+") then "<HOSTNAME>"
                        elif test("^(/.{2,}|[A-Z]:[/\\\\\\\\]|~/)") then "<PATH>"
                        else .
                        end
                    )
                ),
                env: (
                    .value.env // {} | to_entries | map({
                        key: .key,
                        value: "<REDACTED>"
                    }) | from_entries
                )
            } | if .args == [] then del(.args) else . end
              | if .env == {} then del(.env) else . end)
        }) | from_entries
    )
}
JQFILTER

    jq -f "$jq_tmp" "$src" > "$dest"
    rm -f "$jq_tmp"
    log_info "  Sanitized claude.json (MCP servers with redacted credentials)"
}

sanitize_settings() {
    local src_dir="$BACKUP_DIR/global"
    local dest_dir="$SANITIZE_DIR/global"
    mkdir -p "$dest_dir"

    # Write jq filter to temp file (avoids Windows shell quoting issues)
    local jq_tmp
    jq_tmp=$(mktemp)
    cat > "$jq_tmp" << 'JQFILTER'
(if .permissions.allow then
    .permissions.allow = (
        [.permissions.allow[] |
            if startswith("mcp__") then
                split("__") |
                if length >= 3 then
                    .[0] + "__<server>__" + .[-1]
                else
                    "mcp__<server>"
                end
            else .
            end
        ] | unique
    )
else .
end)
# Redact the top-level env map (values can hold tokens/paths); keys are kept.
| (if .env then .env = (.env | map_values("<REDACTED>")) else . end)
JQFILTER

    for f in settings.json settings.local.json; do
        if [ -f "$src_dir/$f" ]; then
            jq -f "$jq_tmp" "$src_dir/$f" > "$dest_dir/$f"
            log_info "  Sanitized $f (redacted MCP permission names + env values)"
        fi
    done
    rm -f "$jq_tmp"
}

copy_safe_files() {
    local src_dir="$BACKUP_DIR"
    local dest_dir="$SANITIZE_DIR"

    # Copy *.md files from global/ (CLAUDE.md, extra context files)
    if ls "$src_dir/global/"*.md &>/dev/null; then
        mkdir -p "$dest_dir/global"
        for f in "$src_dir/global/"*.md; do
            cp "$f" "$dest_dir/global/"
        done
        log_info "  Copied global markdown files"
    fi

    # Copy keybindings.json if present
    if [ -f "$src_dir/global/keybindings.json" ]; then
        mkdir -p "$dest_dir/global"
        cp "$src_dir/global/keybindings.json" "$dest_dir/global/"
        log_info "  Copied keybindings.json"
    fi

    # Copy entire directories that are safe as-is.
    # Skills and plugins are always safe (no user-identifying content).
    # User-content dirs are defined in USER_CONTENT_DIRS and may contain personal
    # context — the export README flags them for review before sharing.
    local safe_dirs=(skills plugins)
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        safe_dirs+=("${entry%%:*}")
    done
    for category in "${safe_dirs[@]}"; do
        if [ -d "$src_dir/$category" ]; then
            mkdir -p "$dest_dir/$category"
            cp -r "$src_dir/$category/." "$dest_dir/$category/"
            # plugins/data/ is arbitrary plugin state (added in v2.2.0) and was
            # never vetted as credential-free — drop it from the shareable export.
            if [ "$category" = "plugins" ] && [ -d "$dest_dir/plugins/data" ]; then
                rm -rf "$dest_dir/plugins/data"
                log_info "  Excluded plugins/data/ from export (unvetted plugin state)"
            fi
            local count
            count=$(find "$dest_dir/$category" -type f 2>/dev/null | wc -l)
            log_info "  Copied $category/ ($count files)"
        fi
    done
}

prompt_project_memory() {
    local src_projects="$BACKUP_DIR/projects"

    if [ ! -d "$src_projects" ]; then
        log_info "  No project data in backup, skipping"
        return 0
    fi

    local project_dirs=()
    for d in "$src_projects"/*/; do
        [ -d "$d/memory" ] || continue
        project_dirs+=("$(basename "$d")")
    done

    if [ ${#project_dirs[@]} -eq 0 ]; then
        log_info "  No project memory data found"
        return 0
    fi

    # Project-memory selection is interactive. In a non-interactive shell (cron,
    # piped stdin) a bare `read` hits EOF and would exit under `set -e`. Skip the
    # prompts and export no memory — the conservative default for a shareable export.
    if [ ! -t 0 ]; then
        log_warn "  Non-interactive shell — skipping project memory prompts (no memory exported)"
        return 0
    fi

    echo ""
    log_info "Project memory export (sessions/todos are always excluded):"
    echo ""

    local exported=0
    for project in "${project_dirs[@]}"; do
        local mem_dir="$src_projects/$project/memory"
        local file_count
        file_count=$(find "$mem_dir" -type f 2>/dev/null | wc -l)

        echo -en "  Include memory for ${BLUE}${project}${NC} ($file_count files)? [Y/n]: "
        read -r answer
        case "$answer" in
            [nN]|[nN][oO])
                log_info "    Skipped $project"
                ;;
            *)
                local dest="$SANITIZE_DIR/projects/$project/memory"
                mkdir -p "$dest"
                cp -r "$mem_dir/." "$dest/"
                log_info "    Exported $project memory ($file_count files)"
                ((exported++)) || true
                ;;
        esac
    done

    log_info "  Exported memory for $exported project(s)"
}

generate_export_readme() {
    cat > "$SANITIZE_DIR/README.md" << 'EXPORT_README'
# Claude Code Settings Export

This is a sanitized export of Claude Code settings, safe for sharing.

## What's included

| Category | Directory | Description |
|----------|-----------|-------------|
| Global instructions | `global/CLAUDE.md` | Custom instructions for all sessions |
| Extra context | `global/*.md` | Additional markdown context files |
| Settings | `global/settings.json` | Permissions, plugins, preferences |
| Keybindings | `global/keybindings.json` | Custom key bindings |
| MCP config | `global/claude.json` | Server definitions (credentials redacted) |
| Skills | `skills/` | Installed skill packages |
| Plugins | `plugins/` | Plugin registry (arbitrary `plugins/data/` state excluded from export) |
| Plans | `plans/` | Saved implementation plans |
| Commands | `commands/` | Custom slash commands |
| Subagents | `agents/` | Custom subagent definitions (if any) |
| Output styles | `output-styles/` | Custom output style definitions (if any) |
| Rules | `rules/` | Topic-scoped instruction files (if any) |
| Hooks | `hooks/` | Hook scripts referenced by `settings.json` (if any) |
| Scheduled tasks | `scheduled-tasks/` | User-defined scheduled task skills (if any) |
| Project memory | `projects/` | Per-project context (if selected) |

## What was redacted

- **MCP server credentials:** Hostnames, usernames, SSH key paths, auth tokens, and URLs replaced with placeholders (`<HOSTNAME>`, `<USERNAME>`, `<SSH_KEY_PATH>`, `<AUTH_TOKEN>`, `<URL>`, `<PATH>`)
- **MCP environment variables:** All values replaced with `<REDACTED>`
- **settings.json env values:** Top-level `env` map values replaced with `<REDACTED>` (keys kept)
- **MCP permission names:** Server-specific names replaced with `<server>` pattern
- **Account data:** OAuth tokens, user IDs, email addresses removed entirely
- **App state:** Runtime counters, caches, and analytics data removed

## Review before sharing

User-content directories are **copied as-is** and may contain personal context:

- `plans/`, `scheduled-tasks/`, `agents/`, `hooks/`, `rules/` — may reference your
  infrastructure, names, or internal systems. Review each file before publishing.
- `commands/`, `output-styles/` — typically generic, but worth a scan.
- `global/settings.json` `permissions.allow` — **only MCP (`mcp__…`) entries are
  redacted.** Non-MCP rules such as `Bash(ssh <hostname>:*)` are kept verbatim and can
  reveal hostnames, usernames, or internal commands. Review these before sharing.

## Setup instructions

1. Copy files to your `~/.claude/` directory (or use `restore.sh` from the backup guide)
2. Edit `global/claude.json` and replace all `<PLACEHOLDER>` values with your own server details
3. Edit `global/settings.json` and update MCP permission entries to match your server names
4. Restart Claude Code
EXPORT_README

    log_info "  Generated README.md for export"
}

sanitize_and_export() {
    echo -e "${GREEN}Sanitized Export${NC}"
    echo "================"
    echo ""

    # Create the output directory. If it already holds a prior export, clear the
    # export-managed paths first so stale files from a previous run don't linger.
    # Only paths this script writes are removed — never arbitrary user files.
    mkdir -p "$SANITIZE_DIR"
    local _cat
    for _cat in global skills plugins projects README.md "${USER_CONTENT_DIRS[@]%%:*}"; do
        rm -rf "${SANITIZE_DIR:?}/${_cat}"
    done

    log_info "Exporting sanitized settings to: $SANITIZE_DIR"
    echo ""

    # Sanitize sensitive files
    sanitize_claude_json
    sanitize_settings

    # Copy non-sensitive files
    copy_safe_files

    # Interactive project memory selection
    prompt_project_memory

    # Generate README
    echo ""
    generate_export_readme

    # Summary
    echo ""
    local total_files
    total_files=$(find "$SANITIZE_DIR" -type f 2>/dev/null | wc -l)
    log_info "Export complete: $total_files files in $SANITIZE_DIR"
}

# ─── Status ─────────────────────────────────────────────────────────

show_status() {
    echo -e "${GREEN}Claude Code Backup — Status (v${SCRIPT_VERSION})${NC}"
    echo "=============================================="
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi
    cd "$BACKUP_DIR"
    echo "  Backup dir:    $BACKUP_DIR"
    if [ -d .git ]; then
        local branch local_head remote_head
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        echo "  Last commit:   $(git log -1 --format='%h  %ci' 2>/dev/null || echo none)"
        echo "  Commit msg:    $(git log -1 --format='%s' 2>/dev/null || echo none)"
        echo "  Total commits: $(git rev-list --count HEAD 2>/dev/null || echo '?')"
        echo "  Branch:        $branch"
        if git rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
            local_head=$(git rev-parse HEAD 2>/dev/null)
            remote_head=$(git rev-parse "origin/$branch" 2>/dev/null)
            if [ "$local_head" = "$remote_head" ]; then
                echo "  Remote:        in sync with origin/$branch"
            else
                echo "  Remote:        OUT OF SYNC with origin/$branch (unpushed or behind)"
            fi
        else
            echo "  Remote:        no origin/$branch tracking info"
        fi
    else
        log_warn "  Not a git repository"
    fi
    local tree_size
    tree_size=$(du -sh --exclude=.git . 2>/dev/null | cut -f1)   # GNU du (Linux, Git Bash)
    [ -n "$tree_size" ] || tree_size=$(du -sh . 2>/dev/null | cut -f1)  # BSD/macOS du: no --exclude
    echo "  Working tree:  ${tree_size:-?}"
    echo "  Git history:   $(du -sh .git 2>/dev/null | cut -f1)"
}

# ─── Main Flow ──────────────────────────────────────────────────────

main() {
    # Parse arguments
    SANITIZE_MODE=false
    SANITIZE_DIR=""
    local positional_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --sanitize)
                SANITIZE_MODE=true
                if [ -z "$2" ] || [[ "$2" == --* ]]; then
                    log_error "--sanitize requires an output directory argument"
                    echo "Usage: bash backup.sh [backup-directory] --sanitize <output-directory>"
                    exit 1
                fi
                SANITIZE_DIR="$2"
                shift 2
                ;;
            --fast)
                FAST_COMPARE=true
                shift
                ;;
            --status)
                STATUS_MODE=true
                shift
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    # Determine BACKUP_DIR: first positional arg or parent of script directory
    if [ ${#positional_args[@]} -gt 0 ]; then
        BACKUP_DIR="${positional_args[0]}"
    else
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        BACKUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    fi

    if [ "$STATUS_MODE" = "true" ]; then
        show_status
        exit 0
    fi

    echo -e "${GREEN}Claude Code Backup Script v${SCRIPT_VERSION}${NC}"
    echo "=================================="
    echo ""

    # Parse config
    parse_config

    if [ "$FAST_COMPARE" = "true" ]; then
        log_info "Change detection: fast (size + mtime)"
    fi

    # Run all backup functions
    backup_global_settings
    backup_mcp_config
    backup_skills
    backup_plugins
    backup_plugin_data
    backup_user_content
    backup_todos
    backup_projects

    echo ""
    log_info "Backup Summary"
    echo "  Global settings: $COUNTS_GLOBAL"
    echo "  MCP config:      $COUNTS_MCP"
    echo "  Skills:          $COUNTS_SKILLS"
    echo "  Plugins:         $COUNTS_PLUGINS"
    echo "  Plugin data:     ${COUNTS_PLUGIN_DATA:-0}"
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        local name="${entry%%:*}"
        local count="${USER_CONTENT_COUNTS[$name]:-0}"
        # Pad name to fixed width for alignment
        printf "  %-16s %s\n" "${name}:" "$count"
    done
    echo "  Todos:           $COUNTS_TODOS"
    echo "  Projects:        $COUNTS_PROJECTS"
    echo ""

    # Git operations
    cd "$BACKUP_DIR"

    if [ ! -d ".git" ]; then
        log_warn "Not a git repository, skipping git operations"
        return 0
    fi

    local push_failed=false

    # Stage specific backup directories (only dirs that might exist)
    local stage_dirs=(global skills plugins todos projects)
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        stage_dirs+=("${entry%%:*}")
    done
    for dir in "${stage_dirs[@]}"; do
        if [ -d "$BACKUP_DIR/$dir" ]; then
            if ! git add "$BACKUP_DIR/$dir"; then
                log_error "git add failed for '$dir' -- a stale .git/index.lock (crash/power loss) or repo corruption can cause this; aborting so it is not masked as 'No changes detected'"
                exit 1
            fi
        fi
    done

    # Stage the repo metadata too, so a fresh clone is a valid, restorable backup
    # (restore.sh hard-fails without backup-config.json). Same fail-loud policy as above.
    for meta_file in backup-config.json .gitignore; do
        if [ -f "$BACKUP_DIR/$meta_file" ]; then
            if ! git add "$BACKUP_DIR/$meta_file"; then
                log_error "git add failed for '$meta_file' -- a stale .git/index.lock or repo corruption can cause this; aborting"
                exit 1
            fi
        fi
    done

    # Check if there are staged changes
    if git diff --cached --quiet 2>/dev/null; then
        log_info "No changes detected, nothing to commit"
    else
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        git commit -m "Backup Claude Code settings -- $timestamp"
        log_info "Changes committed"

        if [ "$GIT_AUTO_PUSH" = "true" ]; then
            log_info "Pushing to $GIT_REMOTE/$GIT_BRANCH..."
            if git push "$GIT_REMOTE" "$GIT_BRANCH" 2>/dev/null; then
                log_info "Push successful"
            elif git push "$GIT_REMOTE" master 2>/dev/null; then
                log_warn "Pushed to master (configured branch '$GIT_BRANCH' failed)"
            else
                log_error "Push failed -- the local commit succeeded but the off-machine copy is now out of sync; please push manually"
                push_failed=true
            fi
        fi
    fi

    # Sanitized export if requested
    if [ "$SANITIZE_MODE" = "true" ]; then
        echo ""
        sanitize_and_export
    fi

    # Final summary
    echo ""
    local last_hash
    last_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
    log_info "Backup complete. Last commit: $last_hash"

    # A failed auto-push means the disaster-recovery copy is stale. Exit non-zero
    # so the Windows observability layer (LastTaskResult / watchdog) reflects
    # reality instead of toasting success while the remote silently ages out.
    if [ "$push_failed" = true ]; then
        log_error "Exiting non-zero: git_auto_push is enabled but the push failed."
        exit 1
    fi
}

main "$@"
