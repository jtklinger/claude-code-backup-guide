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
# Usage: bash backup.sh [backup-directory] [--sanitize <output-directory>]
#
# Fully non-interactive — safe for cron.

set -e

SCRIPT_VERSION="2.1.0"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global state
CHANGES_MADE=false
COUNTS_GLOBAL=0
COUNTS_MCP=0
COUNTS_SKILLS=0
COUNTS_PLUGINS=0
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

    # Read projects array
    PROJECTS=()
    while IFS= read -r proj; do
        proj="${proj%$'\r'}"  # Strip Windows carriage return
        [ -n "$proj" ] && PROJECTS+=("$proj")
    done < <(jq -r '.projects[]? // empty' "$config_file")

    # Expand ~ to $HOME in claude_dir
    CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

    log_info "Config loaded: claude_dir=$CLAUDE_DIR, ${#PROJECTS[@]} project(s)"
}

copy_if_changed() {
    local source="$1"
    local dest="$2"

    if [ ! -e "$source" ]; then
        log_warn "Source not found, skipping: $source"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"

    if [ -f "$dest" ] && cmp -s "$source" "$dest"; then
        return 0
    fi

    cp "$source" "$dest"
    CHANGES_MADE=true
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
        local rel_path="${src_file#$source_dir/}"
        local dest_file="$dest_dir/$rel_path"
        mkdir -p "$(dirname "$dest_file")"
        if [ ! -f "$dest_file" ] || ! cmp -s "$src_file" "$dest_file"; then
            cp "$src_file" "$dest_file"
            CHANGES_MADE=true
            ((copied++)) || true
        fi
    done < <(find "$source_dir" -type f -name "$file_glob" -print0 2>/dev/null)

    # Remove stale files from dest that no longer exist in source
    if [ -d "$dest_dir" ]; then
        while IFS= read -r -d '' dest_file; do
            local rel_path="${dest_file#$dest_dir/}"
            local src_file="$source_dir/$rel_path"
            if [ ! -f "$src_file" ]; then
                rm -f "$dest_file"
                CHANGES_MADE=true
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

    # Back up all *.md files from claude_dir (CLAUDE.md, PROJECT-CONTEXT.md, etc.)
    if ls "$CLAUDE_DIR"/*.md &>/dev/null; then
        for md_file in "$CLAUDE_DIR"/*.md; do
            local basename
            basename=$(basename "$md_file")
            copy_if_changed "$md_file" "$dest_dir/$basename"
            ((count++)) || true
        done
    fi

    # Specific JSON config files
    for f in settings.json settings.local.json keybindings.json; do
        if [ -f "$CLAUDE_DIR/$f" ]; then
            copy_if_changed "$CLAUDE_DIR/$f" "$dest_dir/$f"
            ((count++)) || true
        fi
    done

    # Remove stale *.md files from dest that no longer exist in source
    if ls "$dest_dir"/*.md &>/dev/null; then
        for dest_md in "$dest_dir"/*.md; do
            local basename
            basename=$(basename "$dest_md")
            if [ ! -f "$CLAUDE_DIR/$basename" ]; then
                rm -f "$dest_md"
                CHANGES_MADE=true
            fi
        done
    fi

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
        local rsync_out
        rsync_out=$(rsync -ai --delete --exclude='.git' "$source_dir/" "$dest_dir/" 2>&1) || true
        # rsync -i prints itemized changes; if output is non-empty, something changed
        if [ -n "$rsync_out" ]; then
            CHANGES_MADE=true
        fi
    else
        # Manual sync fallback — copy all files excluding .git
        mkdir -p "$dest_dir"
        local copied=0
        while IFS= read -r -d '' src_file; do
            local rel_path="${src_file#$source_dir/}"
            local dest_file="$dest_dir/$rel_path"
            mkdir -p "$(dirname "$dest_file")"
            if [ ! -f "$dest_file" ] || ! cmp -s "$src_file" "$dest_file"; then
                cp "$src_file" "$dest_file"
                CHANGES_MADE=true
                ((copied++)) || true
            fi
        done < <(find "$source_dir" -type f -not -path '*/.git/*' -print0 2>/dev/null)

        # Remove stale files
        if [ -d "$dest_dir" ]; then
            while IFS= read -r -d '' dest_file; do
                local rel_path="${dest_file#$dest_dir/}"
                if [ ! -f "$source_dir/$rel_path" ]; then
                    rm -f "$dest_file"
                    CHANGES_MADE=true
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
            local mem_count
            mem_count=$(sync_directory "$source_dir/memory" "$dest_base/memory")
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
                        CHANGES_MADE=true
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
                        CHANGES_MADE=true
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
                        elif startswith("--header") then .
                        elif test("^(authorization:|Bearer )") then "<AUTH_TOKEN>"
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
if .permissions.allow then
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
end
JQFILTER

    for f in settings.json settings.local.json; do
        if [ -f "$src_dir/$f" ]; then
            jq -f "$jq_tmp" "$src_dir/$f" > "$dest_dir/$f"
            log_info "  Sanitized $f (redacted MCP permission names)"
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
| Plugins | `plugins/` | Plugin registry |
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
- **MCP permission names:** Server-specific names replaced with `<server>` pattern
- **Account data:** OAuth tokens, user IDs, email addresses removed entirely
- **App state:** Runtime counters, caches, and analytics data removed

## Review before sharing

User-content directories are **copied as-is** and may contain personal context:

- `plans/`, `scheduled-tasks/`, `agents/`, `hooks/`, `rules/` — may reference your
  infrastructure, names, or internal systems. Review each file before publishing.
- `commands/`, `output-styles/` — typically generic, but worth a scan.

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

    # Create/clean output directory
    mkdir -p "$SANITIZE_DIR"

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

    echo -e "${GREEN}Claude Code Backup Script v${SCRIPT_VERSION}${NC}"
    echo "=================================="
    echo ""

    # Parse config
    parse_config

    # Run all backup functions
    backup_global_settings
    backup_mcp_config
    backup_skills
    backup_plugins
    backup_user_content
    backup_todos
    backup_projects

    echo ""
    log_info "Backup Summary"
    echo "  Global settings: $COUNTS_GLOBAL"
    echo "  MCP config:      $COUNTS_MCP"
    echo "  Skills:          $COUNTS_SKILLS"
    echo "  Plugins:         $COUNTS_PLUGINS"
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

    # Stage specific backup directories (only dirs that might exist)
    local stage_dirs=(global skills plugins todos projects)
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        stage_dirs+=("${entry%%:*}")
    done
    for dir in "${stage_dirs[@]}"; do
        if [ -d "$BACKUP_DIR/$dir" ]; then
            git add "$BACKUP_DIR/$dir" 2>/dev/null || true
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
                log_error "Push failed -- please push manually"
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
}

main "$@"
