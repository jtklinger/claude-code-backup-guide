#!/bin/bash

# Claude Code Settings Backup Script v2
#
# Config-driven backup of all Claude Code data categories.
# Reads backup-config.json from the repo root and backs up
# settings, MCP config, skills, plugins, plans, commands,
# todos, and per-project data.
#
# Usage: bash backup.sh [backup-directory] [--sanitize <output-directory>]
#
# Fully non-interactive — safe for cron.

set -e

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
COUNTS_PLANS=0
COUNTS_COMMANDS=0
COUNTS_TODOS=0
COUNTS_PROJECTS=0

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

    # Back up all *.md files from claude_dir (CLAUDE.md, HOMELAB-CONTEXT.md, etc.)
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

backup_plans() {
    log_info "Backing up plans..."
    local source_dir="$CLAUDE_DIR/plans"
    local dest_dir="$BACKUP_DIR/plans"

    if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir"/*.md 2>/dev/null)" ]; then
        log_warn "  Plans directory empty or missing, skipping"
        return 0
    fi

    local count
    count=$(sync_directory "$source_dir" "$dest_dir" "*.md")
    COUNTS_PLANS=$(find "$dest_dir" -type f -name "*.md" 2>/dev/null | wc -l)
    log_info "  Plans: $COUNTS_PLANS file(s)"
}

backup_commands() {
    log_info "Backing up commands..."
    local source_dir="$CLAUDE_DIR/commands"
    local dest_dir="$BACKUP_DIR/commands"

    if [ ! -d "$source_dir" ] || [ -z "$(ls -A "$source_dir"/*.md 2>/dev/null)" ]; then
        log_warn "  Commands directory empty or missing, skipping"
        return 0
    fi

    local count
    count=$(sync_directory "$source_dir" "$dest_dir" "*.md")
    COUNTS_COMMANDS=$(find "$dest_dir" -type f -name "*.md" 2>/dev/null | wc -l)
    log_info "  Commands: $COUNTS_COMMANDS file(s)"
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

    # jq filter that:
    # 1. Keeps only mcpServers
    # 2. For each server: keeps type and command, redacts args and env
    local jq_filter='
    {
        mcpServers: (
            .mcpServers // {} | to_entries | map({
                key: .key,
                value: {
                    type: .value.type,
                    command: .value.command,
                    args: (
                        .value.args // [] | map(
                            if startswith("--host=") then "--host=<HOSTNAME>"
                            elif startswith("--user=") then "--user=<USERNAME>"
                            elif startswith("--key=") then "--key=<SSH_KEY_PATH>"
                            elif startswith("--header") then .
                            elif test("^(authorization:|Bearer )") then "<AUTH_TOKEN>"
                            elif test("^https?://") then "<URL>"
                            elif test("\\.(com|local|net|org|io)([:/]|$)") then "<HOSTNAME>"
                            elif test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+") then "<HOSTNAME>"
                            elif test("^(/|[A-Z]:[/\\\\]|~/)") then "<PATH>"
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
                  | if .env == {} then del(.env) else . end
            }) | from_entries
        )
    }'

    jq "$jq_filter" "$src" > "$dest"
    log_info "  Sanitized claude.json (MCP servers with redacted credentials)"
}

sanitize_settings() {
    local src_dir="$BACKUP_DIR/global"
    local dest_dir="$SANITIZE_DIR/global"
    mkdir -p "$dest_dir"

    # jq filter: redact mcp__*__* permission entries, deduplicate
    local jq_filter='
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
    end'

    for f in settings.json settings.local.json; do
        if [ -f "$src_dir/$f" ]; then
            jq "$jq_filter" "$src_dir/$f" > "$dest_dir/$f"
            log_info "  Sanitized $f (redacted MCP permission names)"
        fi
    done
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

    # Copy entire directories that are safe as-is
    for category in skills plugins plans commands; do
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

    echo -e "${GREEN}Claude Code Backup Script v2${NC}"
    echo "=============================="
    echo ""

    # Parse config
    parse_config

    # Run all backup functions
    backup_global_settings
    backup_mcp_config
    backup_skills
    backup_plugins
    backup_plans
    backup_commands
    backup_todos
    backup_projects

    echo ""
    log_info "Backup Summary"
    echo "  Global settings: $COUNTS_GLOBAL"
    echo "  MCP config:      $COUNTS_MCP"
    echo "  Skills:           $COUNTS_SKILLS"
    echo "  Plugins:          $COUNTS_PLUGINS"
    echo "  Plans:            $COUNTS_PLANS"
    echo "  Commands:         $COUNTS_COMMANDS"
    echo "  Todos:            $COUNTS_TODOS"
    echo "  Projects:         $COUNTS_PROJECTS"
    echo ""

    # Git operations
    cd "$BACKUP_DIR"

    if [ ! -d ".git" ]; then
        log_warn "Not a git repository, skipping git operations"
        return 0
    fi

    # Stage specific backup directories (only dirs that might exist)
    for dir in global skills plugins plans commands todos projects; do
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
