#!/bin/bash

# Claude Code Settings Restore Script
#
# Config-driven restore of all Claude Code data categories.
# Reads backup-config.json from the repo root and restores
# settings, MCP config, skills, plugins, user-content dirs
# (plans, commands, agents, output-styles, rules, hooks,
# scheduled-tasks), todos, and per-project data (including
# subagent transcripts and tool-result payloads) with
# interactive prompts.
#
# Usage: bash restore.sh [backup-directory] [--yes] [--dry-run]
#
# Options:
#   --yes        Non-interactive mode (skip all prompts, restore everything)
#   --dry-run    Scan only — report which files would be created, changed, or
#                left alone. Writes nothing. Implies --yes so the full picture
#                is shown in one pass. Useful before restoring to a laptop
#                that already has a Claude Code install.

set -e

SCRIPT_VERSION="2.2.0"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global state
AUTO_YES=false
DRY_RUN=false
RESTORED_FILES=()
RESTORED_DIRS=()

# Dry-run classification buckets — one array per category
DRYRUN_NEW=()
DRYRUN_CHANGED=()
DRYRUN_SAME=()

# User-content directories restored via a generic loop.
# Must match the list in backup.sh.
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

log_detail() {
    echo -e "[$(log_ts)] ${BLUE}$1${NC}"
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
        log_error "This does not appear to be a valid backup repository."
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

backup_existing() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_name="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "  Backing up existing $(basename "$file") -> $(basename "$backup_name")"
        cp "$file" "$backup_name"
    fi
}

prompt_restore() {
    local category_name="$1"

    if [ "$AUTO_YES" = "true" ]; then
        return 0
    fi

    echo -en "Restore ${BLUE}${category_name}${NC}? [Y/n]: "
    read -r answer
    case "$answer" in
        [nN]|[nN][oO])
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Either copy the file (normal mode) or classify the change (dry-run mode).
# In dry-run mode the file is never written; only classification counters
# and on-screen NEW/CHANGED lines are emitted.
report_or_copy() {
    local src="$1"
    local dest="$2"

    if [ "$DRY_RUN" = "true" ]; then
        if [ ! -f "$dest" ]; then
            DRYRUN_NEW+=("$dest")
            local src_size
            src_size=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
            echo -e "    ${GREEN}NEW${NC}      $dest (${src_size} bytes)"
        elif cmp -s "$src" "$dest"; then
            DRYRUN_SAME+=("$dest")
            # Unchanged files are silent by default — shown only in summary
        else
            DRYRUN_CHANGED+=("$dest")
            local src_size dest_size
            src_size=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
            dest_size=$(wc -c < "$dest" 2>/dev/null | tr -d ' ')
            echo -e "    ${YELLOW}CHANGED${NC}  $dest (${dest_size} -> ${src_size} bytes)"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    backup_existing "$dest"
    cp "$src" "$dest"
    RESTORED_FILES+=("$dest")
    return 0
}

# Copy a single file from backup to destination, with backup_existing
restore_file() {
    local src="$1"
    local dest="$2"

    if [ ! -f "$src" ]; then
        return 1
    fi

    report_or_copy "$src" "$dest"
    return 0
}

# ─── Restore Functions ──────────────────────────────────────────────

restore_global_settings() {
    log_info "Restoring global settings..."
    local source_dir="$BACKUP_DIR/global"
    local count=0

    if [ ! -d "$source_dir" ]; then
        log_warn "  No global/ directory found in backup, skipping"
        return 0
    fi

    # CLAUDE.md
    if restore_file "$source_dir/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"; then
        log_detail "  Restored CLAUDE.md"
        ((count++)) || true
    fi

    # settings.json
    if restore_file "$source_dir/settings.json" "$CLAUDE_DIR/settings.json"; then
        log_detail "  Restored settings.json"
        ((count++)) || true
    fi

    # settings.local.json
    if restore_file "$source_dir/settings.local.json" "$CLAUDE_DIR/settings.local.json"; then
        log_detail "  Restored settings.local.json"
        ((count++)) || true
    fi

    # keybindings.json (optional)
    if restore_file "$source_dir/keybindings.json" "$CLAUDE_DIR/keybindings.json"; then
        log_detail "  Restored keybindings.json"
        ((count++)) || true
    fi

    # Extra *.md context files (e.g., PROJECT-CONTEXT.md)
    if ls "$source_dir"/*.md &>/dev/null; then
        for md_file in "$source_dir"/*.md; do
            local basename
            basename=$(basename "$md_file")
            # CLAUDE.md already handled above
            if [ "$basename" = "CLAUDE.md" ]; then
                continue
            fi
            if restore_file "$md_file" "$CLAUDE_DIR/$basename"; then
                log_detail "  Restored $basename"
                ((count++)) || true
            fi
        done
    fi

    log_info "  Global settings: $count file(s) restored"
}

restore_mcp_config() {
    log_info "Restoring MCP config..."
    local source_dir="$BACKUP_DIR/global"

    if [ ! -f "$source_dir/claude.json" ]; then
        log_warn "  No claude.json found in backup, skipping"
        return 0
    fi

    # claude.json lives in HOME, not inside .claude/
    restore_file "$source_dir/claude.json" "$HOME/.claude.json"
    log_detail "  Restored ~/.claude.json"
    log_warn "  WARNING: This overwrites OAuth tokens. You may need to re-authenticate."

    log_info "  MCP config: 1 file restored"
}

restore_skills() {
    log_info "Restoring skills..."
    local source_dir="$BACKUP_DIR/skills"
    local dest_dir="$CLAUDE_DIR/skills"

    if [ ! -d "$source_dir" ]; then
        log_warn "  No skills/ directory found in backup, skipping"
        return 0
    fi

    local count=0
    if [ "$DRY_RUN" != "true" ]; then
        mkdir -p "$dest_dir"
    fi

    while IFS= read -r -d '' src_file; do
        local rel_path="${src_file#$source_dir/}"
        local dest_file="$dest_dir/$rel_path"
        report_or_copy "$src_file" "$dest_file"
        ((count++)) || true
    done < <(find "$source_dir" -type f -not -path '*/.git/*' -print0 2>/dev/null)

    RESTORED_DIRS+=("$dest_dir")
    log_info "  Skills: $count file(s) processed"
}

restore_plugins() {
    log_info "Restoring plugins..."
    local source_dir="$BACKUP_DIR/plugins"
    local dest_dir="$CLAUDE_DIR/plugins"

    if [ ! -d "$source_dir" ]; then
        log_warn "  No plugins/ directory found in backup, skipping"
        return 0
    fi

    local count=0
    mkdir -p "$dest_dir"

    for f in installed_plugins.json blocklist.json known_marketplaces.json; do
        if restore_file "$source_dir/$f" "$dest_dir/$f"; then
            log_detail "  Restored $f"
            ((count++)) || true
        fi
    done

    log_info "  Plugins: $count file(s) restored"
    if [ "$count" -gt 0 ]; then
        log_detail "  Note: plugins will re-download their cache on next launch"
    fi
}

restore_user_content() {
    local name="$1"
    local glob="${2:-*}"
    local source_dir="$BACKUP_DIR/$name"
    local dest_dir="$CLAUDE_DIR/$name"

    log_info "Restoring $name..."

    if [ ! -d "$source_dir" ]; then
        log_warn "  No $name/ directory found in backup, skipping"
        return 0
    fi

    local count=0
    mkdir -p "$dest_dir"

    # Walk the backup dir recursively so nested structure (e.g. scheduled-tasks/<task>/SKILL.md)
    # is preserved on restore.
    while IFS= read -r -d '' src_file; do
        local rel_path="${src_file#$source_dir/}"
        local dest_file="$dest_dir/$rel_path"
        mkdir -p "$(dirname "$dest_file")"
        if restore_file "$src_file" "$dest_file"; then
            ((count++)) || true
        fi
    done < <(find "$source_dir" -type f -name "$glob" -print0 2>/dev/null)

    log_info "  $name: $count file(s) restored"
}

restore_todos() {
    log_info "Restoring todos..."
    local source_dir="$BACKUP_DIR/todos"
    local dest_dir="$CLAUDE_DIR/todos"

    if [ ! -d "$source_dir" ]; then
        log_warn "  No todos/ directory found in backup, skipping"
        return 0
    fi

    local count=0
    mkdir -p "$dest_dir"

    for json_file in "$source_dir"/*.json; do
        [ -f "$json_file" ] || continue
        local basename
        basename=$(basename "$json_file")
        if restore_file "$json_file" "$dest_dir/$basename"; then
            ((count++)) || true
        fi
    done

    log_info "  Todos: $count file(s) restored"
}

restore_projects() {
    local projects_dir="$BACKUP_DIR/projects"

    if [ ! -d "$projects_dir" ]; then
        log_warn "No projects/ directory found in backup, skipping"
        return 0
    fi

    # Discover project directories in the backup
    local project_dirs=()
    for d in "$projects_dir"/*/; do
        [ -d "$d" ] || continue
        project_dirs+=("$(basename "$d")")
    done

    if [ ${#project_dirs[@]} -eq 0 ]; then
        log_warn "  No project data found in backup, skipping"
        return 0
    fi

    log_info "Restoring ${#project_dirs[@]} project(s)..."
    local total_count=0

    for project in "${project_dirs[@]}"; do
        local src_base="$projects_dir/$project"
        local dest_base="$CLAUDE_DIR/projects/$project"
        local proj_count=0

        log_detail "  Project: $project"
        if [ "$DRY_RUN" != "true" ]; then
            mkdir -p "$dest_base"
        fi

        # Restore memory files
        if [ -d "$src_base/memory" ]; then
            while IFS= read -r -d '' src_file; do
                local rel_path="${src_file#$src_base/memory/}"
                local dest_file="$dest_base/memory/$rel_path"
                report_or_copy "$src_file" "$dest_file"
                ((proj_count++)) || true
            done < <(find "$src_base/memory" -type f -print0 2>/dev/null)
            log_detail "    Memory: $proj_count file(s)"
        fi

        # Restore session files
        # Sessions in backup are stored under sessions/ subdir,
        # but Claude Code reads them from the project root dir.
        if [ -d "$src_base/sessions" ]; then
            local session_count=0
            while IFS= read -r -d '' src_file; do
                local basename
                basename=$(basename "$src_file")
                local dest_file="$dest_base/$basename"
                report_or_copy "$src_file" "$dest_file"
                ((session_count++)) || true
            done < <(find "$src_base/sessions" -type f \( -name "*.jsonl" -o -name "*.meta.json" \) -print0 2>/dev/null)
            ((proj_count += session_count)) || true
            log_detail "    Sessions: $session_count file(s) -> project root"
        fi

        # Restore per-session nested data: backup layout is
        # projects/<hash>/<category>/<session-uuid>/<file>, restored to
        # projects/<hash>/<session-uuid>/<category>/<file>.
        for category in subagents tool-results; do
            local src_category="$src_base/$category"
            [ -d "$src_category" ] || continue

            local cat_count=0
            for uuid_dir in "$src_category"/*/; do
                [ -d "$uuid_dir" ] || continue
                local uuid
                uuid=$(basename "$uuid_dir")
                local dest_cat="$dest_base/$uuid/$category"
                if [ "$DRY_RUN" != "true" ]; then
                    mkdir -p "$dest_cat"
                fi

                while IFS= read -r -d '' src_file; do
                    local basename
                    basename=$(basename "$src_file")
                    local dest_file="$dest_cat/$basename"
                    report_or_copy "$src_file" "$dest_file"
                    ((cat_count++)) || true
                done < <(find "$uuid_dir" -type f -print0 2>/dev/null)
            done

            if [ "$cat_count" -gt 0 ]; then
                log_detail "    ${category}: $cat_count file(s)"
                ((proj_count += cat_count)) || true
            fi
        done

        ((total_count += proj_count)) || true
    done

    log_info "  Projects total: $total_count file(s) processed"
}

# ─── Main Flow ──────────────────────────────────────────────────────

main() {
    # Parse arguments
    local positional_args=()
    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                AUTO_YES=true
                ;;
            --dry-run|-n)
                DRY_RUN=true
                AUTO_YES=true  # No point prompting when nothing will be written
                ;;
            *)
                positional_args+=("$arg")
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

    echo -e "${GREEN}Claude Code Restore Script v${SCRIPT_VERSION}${NC}"
    echo "==================================="
    echo ""

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "DRY RUN mode: scanning only — no files will be written."
        log_info "  NEW     = file does not exist at destination"
        log_info "  CHANGED = file exists and differs from the backup"
        log_info "  (unchanged files are silent; counted in summary)"
        echo ""
    elif [ "$AUTO_YES" = "true" ]; then
        log_info "Non-interactive mode (--yes): all categories will be restored"
        echo ""
    fi

    # Parse config
    parse_config

    # Create claude dir if missing (skip in dry-run — we're not writing anything)
    if [ ! -d "$CLAUDE_DIR" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log_warn "Claude Code directory does not exist: $CLAUDE_DIR"
            log_warn "  (would be created during a real restore)"
        else
            log_info "Creating Claude Code directory: $CLAUDE_DIR"
            mkdir -p "$CLAUDE_DIR"
        fi
    fi

    echo ""

    # Restore each category with interactive prompts
    if prompt_restore "Global settings (CLAUDE.md, settings.json, etc.)"; then
        restore_global_settings
    else
        log_info "Skipped global settings"
    fi
    echo ""

    if prompt_restore "MCP config (~/.claude.json)"; then
        restore_mcp_config
    else
        log_info "Skipped MCP config"
    fi
    echo ""

    if prompt_restore "Skills"; then
        restore_skills
    else
        log_info "Skipped skills"
    fi
    echo ""

    if prompt_restore "Plugins"; then
        restore_plugins
    else
        log_info "Skipped plugins"
    fi
    echo ""

    # User-content categories (plans, commands, agents, output-styles, rules, hooks,
    # scheduled-tasks). Only prompt for ones that actually exist in the backup so
    # users aren't asked about categories they've never used.
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        local uc_name="${entry%%:*}"
        local uc_glob="${entry#*:}"
        local uc_src="$BACKUP_DIR/$uc_name"

        if [ ! -d "$uc_src" ] || [ -z "$(find "$uc_src" -type f 2>/dev/null | head -1)" ]; then
            continue
        fi

        if prompt_restore "$uc_name"; then
            restore_user_content "$uc_name" "$uc_glob"
        else
            log_info "Skipped $uc_name"
        fi
        echo ""
    done

    if [ "$INCLUDE_TODOS" = "true" ]; then
        if prompt_restore "Todos"; then
            restore_todos
        else
            log_info "Skipped todos"
        fi
    else
        log_info "Todos disabled in config, skipping"
    fi
    echo ""

    if prompt_restore "Projects (${#PROJECTS[@]} configured)"; then
        restore_projects
    else
        log_info "Skipped projects"
    fi
    echo ""

    # ─── Summary ────────────────────────────────────────────────────
    echo ""

    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${GREEN}Dry Run Summary${NC}"
        echo "================="
        echo ""
        echo -e "  ${GREEN}NEW${NC}      ${#DRYRUN_NEW[@]} file(s) would be created"
        echo -e "  ${YELLOW}CHANGED${NC}  ${#DRYRUN_CHANGED[@]} file(s) would overwrite existing content"
        echo "  SAME     ${#DRYRUN_SAME[@]} file(s) identical to backup (timestamp-backed-up then re-copied)"
        echo ""

        if [ "${#DRYRUN_CHANGED[@]}" -gt 0 ]; then
            log_warn "${#DRYRUN_CHANGED[@]} existing file(s) would be overwritten."
            log_warn "Each existing file is first copied to <file>.backup.<timestamp> before overwrite."
            echo ""

            # Flag claude.json specifically — overwriting nukes OAuth tokens
            for f in "${DRYRUN_CHANGED[@]}"; do
                if [[ "$f" == *"/.claude.json" ]]; then
                    log_warn "NOTE: ~/.claude.json is in the CHANGED set — restoring will replace"
                    log_warn "      OAuth tokens on this machine. You'll need to re-authenticate."
                    echo ""
                    break
                fi
            done
        fi

        echo "Run without --dry-run to apply the changes."
        log_info "Dry run complete."
        return 0
    fi

    echo -e "${GREEN}Restore Verification Summary${NC}"
    echo "=============================="

    if [ ${#RESTORED_FILES[@]} -gt 0 ]; then
        echo ""
        echo "Restored files (${#RESTORED_FILES[@]} total):"
        # Show key directories with sizes
        local shown_dirs=()

        # Show individual files in CLAUDE_DIR root
        for f in "$CLAUDE_DIR"/*.md "$CLAUDE_DIR"/*.json; do
            [ -f "$f" ] || continue
            local size
            size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
            echo "  $f ($size bytes)"
        done

        # Show restored subdirectories with file counts
        local summary_dirs=(skills plugins todos projects)
        for uc_entry in "${USER_CONTENT_DIRS[@]}"; do
            summary_dirs+=("${uc_entry%%:*}")
        done
        for subdir in "${summary_dirs[@]}"; do
            local full_dir="$CLAUDE_DIR/$subdir"
            if [ -d "$full_dir" ]; then
                local file_count
                file_count=$(find "$full_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                local dir_size
                dir_size=$(du -sh "$full_dir" 2>/dev/null | cut -f1 || echo "unknown")
                echo "  $full_dir/ ($file_count files, $dir_size)"
            fi
        done

        # Show ~/.claude.json if it was restored
        if [ -f "$HOME/.claude.json" ]; then
            local size
            size=$(wc -c < "$HOME/.claude.json" 2>/dev/null | tr -d ' ')
            echo "  $HOME/.claude.json ($size bytes)"
        fi
    else
        echo ""
        echo "  No files were restored."
    fi

    # ─── Next Steps ─────────────────────────────────────────────────
    echo ""
    echo -e "${BLUE}Next Steps${NC}"
    echo "=========="
    echo ""
    echo "1. Restart Claude Code to apply restored settings"
    echo ""

    # Check if claude.json was restored
    local claude_json_restored=false
    for f in "${RESTORED_FILES[@]}"; do
        if [[ "$f" == *".claude.json" ]]; then
            claude_json_restored=true
            break
        fi
    done
    if [ "$claude_json_restored" = "true" ]; then
        echo -e "2. ${YELLOW}MCP config was restored -- you may need to re-authenticate${NC}"
        echo "   (OAuth tokens in ~/.claude.json may be stale)"
        echo ""
    fi

    echo "3. Verify MCP servers are working:"
    echo "   claude mcp list"
    echo ""

    log_info "Restore complete!"
}

main "$@"
