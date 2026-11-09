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
# Usage: bash restore.sh [backup-directory] [--yes] [--dry-run] [--skip <list> | --only <list>]
#
# Options:
#   --yes        Non-interactive mode (skip all prompts, restore everything)
#   --dry-run    Scan only — report which files would be created, changed, or
#                left alone. Writes nothing. Implies --yes so the full picture
#                is shown in one pass. Useful before restoring to a laptop
#                that already has a Claude Code install.
#   --skip LIST  Leave out these comma-separated categories (e.g. mcp,todos).
#   --only LIST  Restore only these categories. Categories: global, mcp, skills,
#                plugins, plans, commands, agents, output-styles, rules, hooks,
#                scheduled-tasks, todos, projects.

set -e

SCRIPT_VERSION="2.5.1"

# This backup toolkit requires bash 4+ (backup.sh uses associative arrays). Enforce
# the same requirement here so a fresh-machine restore fails early with a clear
# message on stock macOS bash 3.2 rather than partway through.
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
AUTO_YES=false
DRY_RUN=false
RESTORED_FILES=()
RESTORED_DIRS=()
IDENTICAL_COUNT=0
MISSING_IMPORTS=()
SELECT_MODE=""       # "skip" or "only" when --skip/--only was given
SELECT_LIST=""       # ",a,b," so a category can be matched with its commas

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
    # Not `// true`: jq's // also replaces an explicit false.
    INCLUDE_SESSIONS=$(jq -r 'if .include_sessions == null then true else .include_sessions end' "$config_file" | tr -d '\r')
    INCLUDE_TODOS=$(jq -r 'if .include_todos == null then true else .include_todos end' "$config_file" | tr -d '\r')

    # Read projects array
    PROJECTS=()
    while IFS= read -r proj; do
        proj="${proj%$'\r'}"  # Strip Windows carriage return
        [ -n "$proj" ] && PROJECTS+=("$proj")
    done < <(jq -r '.projects[]? // empty' "$config_file")

    # Expand ~ to $HOME in claude_dir
    CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

    # Note: PROJECTS holds the raw config patterns (e.g. ["*"]) and is not used to
    # drive restore — restore_projects() scans the backup dir directly. Don't print
    # a pattern count here; it would misrepresent how many projects are in the backup
    # (the accurate count is shown at the Projects prompt and by restore_projects()).
    log_info "Config loaded: claude_dir=$CLAUDE_DIR"
}

backup_existing() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_name="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "  Backing up existing $(basename "$file") -> $(basename "$backup_name")"
        cp "$file" "$backup_name"
    fi
}

# set_selection <skip|only> <comma-separated categories>
# Runs during argument parsing, so a typo stops the restore before anything is written.
set_selection() {
    local mode="$1" value="$2" item entry
    if [ -n "$SELECT_MODE" ]; then
        log_error "Use --skip or --only once, not both or repeatedly."
        exit 1
    fi
    if [ -z "$value" ] || [[ "$value" == --* ]]; then
        log_error "--$mode requires a comma-separated list of categories."
        exit 1
    fi

    local valid=" global mcp skills plugins todos projects "
    for entry in "${USER_CONTENT_DIRS[@]}"; do
        valid+="${entry%%:*} "
    done
    local -a items
    IFS=',' read -ra items <<< "$value"
    for item in "${items[@]}"; do
        if [[ "$valid" != *" $item "* ]]; then
            log_error "Unknown category for --$mode: '$item'. Valid categories:$valid"
            exit 1
        fi
    done

    SELECT_MODE="$mode"
    SELECT_LIST=",$value,"
}

category_selected() {
    case "$SELECT_MODE" in
        skip) [[ "$SELECT_LIST" != *",$1,"* ]] ;;
        only) [[ "$SELECT_LIST" == *",$1,"* ]] ;;
        *) return 0 ;;
    esac
}

# prompt_restore <category key> <label shown in the prompt>
prompt_restore() {
    local category_name="$2"

    category_selected "$1" || return 1

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

# Says where the backup came from, and warns if that was another machine.
# Backups made before the manifest existed have none, so it is optional.
show_manifest() {
    local manifest="$BACKUP_DIR/backup-manifest.json"
    [ -f "$manifest" ] || return 0

    local source_host this_host summary
    source_host=$(jq -r '.hostname // "unknown"' "$manifest" | tr -d '\r')
    this_host=$(uname -n | tr -d '\r' | cut -d. -f1)
    summary=$(jq -r '"\(.os // "unknown OS"), \(.timestamp // "unknown time"), Claude Code \(.claude_code_version // "unknown"), script \(.script_version // "unknown")"' "$manifest" | tr -d '\r')
    log_info "Backup made on $source_host ($summary)"

    if [ "$source_host" != "$this_host" ]; then
        log_warn "WARNING: this backup was made on a different machine: $source_host (this machine: $this_host)."
        log_warn "It carries that machine's CLAUDE.md host facts, memory, and sessions."
    fi
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

    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        IDENTICAL_COUNT=$((IDENTICAL_COUNT + 1))
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

# Claude Code skips an @-import whose target is missing without saying so. Read the
# backup's copies, so this works the same in --dry-run. Only a line that is nothing
# but an @-path counts; an @name in prose is not an import.
find_missing_imports() {
    local source_dir="$1" md_file target resolved
    for md_file in "$source_dir"/*.md; do
        [ -f "$md_file" ] || continue
        while IFS= read -r target; do
            target="${target#@}"
            target="${target%%[[:space:]]*}"
            target="${target/#\~/$HOME}"
            case "$target" in
                /*|[A-Za-z]:*) [ -e "$target" ] && continue ;;
                *)
                    resolved="$CLAUDE_DIR/$target"
                    { [ -e "$resolved" ] || [ -e "$source_dir/$target" ]; } && continue
                    ;;
            esac
            MISSING_IMPORTS+=("$(basename "$md_file") imports $target")
        done < <(grep -E '^@[^[:space:]]*[/.][^[:space:]]*[[:space:]]*$' "$md_file" | tr -d '\r')
    done
}

show_missing_imports() {
    [ "${#MISSING_IMPORTS[@]}" -gt 0 ] || return 0
    local entry
    for entry in "${MISSING_IMPORTS[@]}"; do
        log_warn "WARNING: $entry, which does not exist on this machine. Claude Code will skip that import silently."
    done
    echo ""
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

    # Custom root scripts (*.cmd, *.ps1, *.js, *.sh, *.py) — mirror backup_global_settings
    for ext in cmd ps1 js sh py; do
        if ls "$source_dir"/*."$ext" &>/dev/null; then
            for script_file in "$source_dir"/*."$ext"; do
                local sbasename
                sbasename=$(basename "$script_file")
                if restore_file "$script_file" "$CLAUDE_DIR/$sbasename"; then
                    log_detail "  Restored $sbasename"
                    ((count++)) || true
                fi
            done
        fi
    done

    find_missing_imports "$source_dir"

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
        local rel_path="${src_file#"$source_dir"/}"
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
    if [ "$DRY_RUN" != "true" ]; then
        mkdir -p "$dest_dir"
    fi

    for f in installed_plugins.json blocklist.json known_marketplaces.json; do
        if restore_file "$source_dir/$f" "$dest_dir/$f"; then
            log_detail "  Restored $f"
            ((count++)) || true
        fi
    done

    # Plugin data (arbitrary plugin state under plugins/data/) — walk recursively,
    # mirroring backup_plugin_data's nested structure.
    local data_src="$source_dir/data"
    if [ -d "$data_src" ]; then
        local data_dest="$dest_dir/data"
        while IFS= read -r -d '' src_file; do
            local rel_path="${src_file#"$data_src"/}"
            local dest_file="$data_dest/$rel_path"
            if [ "$DRY_RUN" != "true" ]; then
                mkdir -p "$(dirname "$dest_file")"
            fi
            if restore_file "$src_file" "$dest_file"; then
                ((count++)) || true
            fi
        done < <(find "$data_src" -type f -not -path '*/.git/*' -print0 2>/dev/null)
    fi

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
    if [ "$DRY_RUN" != "true" ]; then
        mkdir -p "$dest_dir"
    fi

    # Walk the backup dir recursively so nested structure (e.g. scheduled-tasks/<task>/SKILL.md)
    # is preserved on restore.
    while IFS= read -r -d '' src_file; do
        local rel_path="${src_file#"$source_dir"/}"
        local dest_file="$dest_dir/$rel_path"
        if [ "$DRY_RUN" != "true" ]; then
            mkdir -p "$(dirname "$dest_file")"
        fi
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
    if [ "$DRY_RUN" != "true" ]; then
        mkdir -p "$dest_dir"
    fi

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
                local rel_path="${src_file#"$src_base"/memory/}"
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
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y)
                AUTO_YES=true
                ;;
            --dry-run|-n)
                DRY_RUN=true
                AUTO_YES=true  # No point prompting when nothing will be written
                ;;
            --skip|--only)
                set_selection "${1#--}" "${2:-}"
                shift
                ;;
            --skip=*|--only=*)
                local option="${1%%=*}"
                set_selection "${option#--}" "${1#*=}"
                ;;
            *)
                positional_args+=("$1")
                ;;
        esac
        shift
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
    show_manifest

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
    if prompt_restore global "Global settings (CLAUDE.md, settings.json, etc.)"; then
        restore_global_settings
    else
        log_info "Skipped global settings"
    fi
    echo ""

    if prompt_restore mcp "MCP config (~/.claude.json)"; then
        restore_mcp_config
    else
        log_info "Skipped MCP config"
    fi
    echo ""

    if prompt_restore skills "Skills"; then
        restore_skills
    else
        log_info "Skipped skills"
    fi
    echo ""

    if prompt_restore plugins "Plugins"; then
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

        if prompt_restore "$uc_name" "$uc_name"; then
            restore_user_content "$uc_name" "$uc_glob"
        else
            log_info "Skipped $uc_name"
        fi
        echo ""
    done

    if [ "$INCLUDE_TODOS" = "true" ]; then
        if prompt_restore todos "Todos"; then
            restore_todos
        else
            log_info "Skipped todos"
        fi
    else
        log_info "Todos disabled in config, skipping"
    fi
    echo ""

    # Count the actual project directories present in the backup (one config
    # pattern like "*" can expand to dozens), not the raw pattern count.
    local backup_project_count=0
    if [ -d "$BACKUP_DIR/projects" ]; then
        for d in "$BACKUP_DIR/projects"/*/; do
            [ -d "$d" ] && ((backup_project_count++)) || true
        done
    fi
    if prompt_restore projects "Projects ($backup_project_count in backup)"; then
        restore_projects
    else
        log_info "Skipped projects"
    fi
    echo ""

    # ─── Summary ────────────────────────────────────────────────────
    echo ""
    show_missing_imports

    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${GREEN}Dry Run Summary${NC}"
        echo "================="
        echo ""
        echo -e "  ${GREEN}NEW${NC}      ${#DRYRUN_NEW[@]} file(s) would be created"
        echo -e "  ${YELLOW}CHANGED${NC}  ${#DRYRUN_CHANGED[@]} file(s) would overwrite existing content"
        echo "  SAME     ${#DRYRUN_SAME[@]} file(s) identical to backup (left alone)"
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

    echo ""
    if [ ${#RESTORED_FILES[@]} -gt 0 ]; then
        echo "Restored files (${#RESTORED_FILES[@]} total):"
        local -A group_counts=()
        local restored_file relative group
        for restored_file in "${RESTORED_FILES[@]}"; do
            if [ "$restored_file" = "$HOME/.claude.json" ]; then
                group="~/.claude.json"
            else
                relative="${restored_file#"$CLAUDE_DIR"/}"
                case "$relative" in
                    */*) group="${relative%%/*}" ;;
                    *) group="global settings" ;;
                esac
            fi
            group_counts[$group]=$(( ${group_counts[$group]:-0} + 1 ))
        done
        while IFS= read -r group; do
            echo "  $group: ${group_counts[$group]} file(s)"
        done < <(printf '%s\n' "${!group_counts[@]}" | sort)
    else
        echo "  No files were restored."
    fi
    if [ "$IDENTICAL_COUNT" -gt 0 ]; then
        echo "  $IDENTICAL_COUNT file(s) already identical to the backup (left alone)"
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
