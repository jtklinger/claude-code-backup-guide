# Sanitized Export Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `--sanitize <output-dir>` flag to backup.sh that produces a credential-free shareable copy of Claude Code settings.

**Architecture:** Post-process approach — normal backup runs first, then a `sanitize_and_export()` function copies the backup to the output directory with jq transforms applied to sensitive files. Four sub-functions handle: claude.json sanitization, settings sanitization, safe file copying, and interactive per-project memory selection.

**Tech Stack:** Bash, jq

---

### Task 1: Parse --sanitize flag in argument handling

**Files:**
- Modify: `scripts/backup.sh:425-432` (main function argument parsing)

**Step 1: Update argument parsing to extract --sanitize and output dir**

Replace the simple `$1` check in `main()` with a loop that handles both positional args and `--sanitize <dir>`:

```bash
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
```

**Step 2: Add sanitize call at end of main, after git operations**

At the very end of `main()`, before the final log line, add:

```bash
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
```

**Step 3: Update script header comment**

Change line 10 from:
```bash
# Usage: bash backup.sh [backup-directory]
```
to:
```bash
# Usage: bash backup.sh [backup-directory] [--sanitize <output-directory>]
```

**Step 4: Test argument parsing**

Run: `bash scripts/backup.sh /tmp/test-backup --sanitize /tmp/test-export 2>&1 | head -5`

Expected: Normal backup starts (will fail on sanitize_and_export since it doesn't exist yet — that's fine for this step). No argument parsing errors.

**Step 5: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add --sanitize flag parsing to backup.sh"
```

---

### Task 2: Implement sanitize_claude_json()

**Files:**
- Modify: `scripts/backup.sh` (add new function after backup functions, before main)

**Step 1: Write the sanitize_claude_json function**

This function reads `global/claude.json` from the backup directory, applies jq transforms, and writes to the export directory.

```bash
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
```

**Step 2: Test the jq filter standalone against real data**

Run:
```bash
jq '{mcpServers:(.mcpServers // {} | to_entries | map({key:.key,value:{type:.value.type,command:.value.command,args:(.value.args // [] | map(if startswith("--host=") then "--host=<HOSTNAME>" elif startswith("--user=") then "--user=<USERNAME>" elif startswith("--key=") then "--key=<SSH_KEY_PATH>" elif startswith("--header") then . elif test("^(authorization:|Bearer )") then "<AUTH_TOKEN>" elif test("^https?://") then "<URL>" elif test("\\.(com|local|net|org|io)([:/]|$)") then "<HOSTNAME>" elif test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+") then "<HOSTNAME>" elif test("^(/|[A-Z]:[/\\\\]|~/)") then "<PATH>" else . end)),env:(.value.env // {} | to_entries | map({key:.key,value:"<REDACTED>"}) | from_entries)} | if .args == [] then del(.args) else . end | if .env == {} then del(.env) else . end}) | from_entries)}' ~/.claude.json
```

Expected: JSON output with server names preserved, all hostnames/paths/tokens replaced with placeholders, no oauthAccount or app state keys.

**Step 3: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add sanitize_claude_json() for MCP credential redaction"
```

---

### Task 3: Implement sanitize_settings()

**Files:**
- Modify: `scripts/backup.sh` (add new function after sanitize_claude_json)

**Step 1: Write the sanitize_settings function**

```bash
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
                    # mcp__<servername>__<action> -> mcp__<server>__<action>
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
```

**Step 2: Test the jq filter standalone**

Run:
```bash
jq 'if .permissions.allow then .permissions.allow = ([.permissions.allow[] | if startswith("mcp__") then split("__") | if length >= 3 then .[0] + "__<server>__" + .[-1] else "mcp__<server>" end else . end] | unique) else . end' ~/.claude/settings.json
```

Expected: `mcp__ssh-mcp-kvm01__exec` becomes `mcp__<server>__exec`, `mcp__ssh-mcp-kvm01__sudo-exec` becomes `mcp__<server>__sudo-exec`. Generic permissions like `Bash(git:*)` unchanged. Duplicates removed.

**Step 3: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add sanitize_settings() for MCP permission redaction"
```

---

### Task 4: Implement copy_safe_files()

**Files:**
- Modify: `scripts/backup.sh` (add new function)

**Step 1: Write the copy_safe_files function**

Copies all non-sensitive files from the backup to the export directory without modification.

```bash
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
```

**Step 2: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add copy_safe_files() for non-sensitive export data"
```

---

### Task 5: Implement prompt_project_memory()

**Files:**
- Modify: `scripts/backup.sh` (add new function)

**Step 1: Write the prompt_project_memory function**

Interactive per-project prompt. No `--yes` equivalent — sharing should be deliberate.

```bash
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
```

**Step 2: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add prompt_project_memory() for interactive project export"
```

---

### Task 6: Implement sanitize_and_export() orchestrator and generate_export_readme()

**Files:**
- Modify: `scripts/backup.sh` (add orchestrator function + README generator)

**Step 1: Write generate_export_readme**

```bash
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
| Project memory | `projects/` | Per-project context (if selected) |

## What was redacted

- **MCP server credentials:** Hostnames, usernames, SSH key paths, auth tokens, and URLs replaced with placeholders (`<HOSTNAME>`, `<USERNAME>`, `<SSH_KEY_PATH>`, `<AUTH_TOKEN>`, `<URL>`, `<PATH>`)
- **MCP environment variables:** All values replaced with `<REDACTED>`
- **MCP permission names:** Server-specific names replaced with `<server>` pattern
- **Account data:** OAuth tokens, user IDs, email addresses removed entirely
- **App state:** Runtime counters, caches, and analytics data removed

## Setup instructions

1. Copy files to your `~/.claude/` directory (or use `restore.sh` from the backup guide)
2. Edit `global/claude.json` and replace all `<PLACEHOLDER>` values with your own server details
3. Edit `global/settings.json` and update MCP permission entries to match your server names
4. Restart Claude Code
EXPORT_README

    log_info "  Generated README.md for export"
}
```

**Step 2: Write sanitize_and_export orchestrator**

```bash
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
```

**Step 3: Commit**

```bash
git add scripts/backup.sh
git commit -m "Add sanitize_and_export() orchestrator and export README generator"
```

---

### Task 7: End-to-end test

**Step 1: Run init.sh to set up a test backup**

```bash
mkdir /tmp/test-backup && bash scripts/init.sh /tmp/test-backup
```

Select "all" projects when prompted.

**Step 2: Run backup with --sanitize**

```bash
bash scripts/backup.sh /tmp/test-backup --sanitize /tmp/test-export
```

Expected: Normal backup completes, then sanitized export runs. Interactive prompts for each project's memory.

**Step 3: Verify sanitized claude.json**

```bash
cat /tmp/test-export/global/claude.json | jq .
```

Expected:
- Only `mcpServers` key present (no `oauthAccount`, `userID`, etc.)
- Server names preserved (`bitwarden`, `ssh-mcp-kvm01`, etc.)
- All `--host=` args show `--host=<HOSTNAME>`
- All `--user=` args show `--user=<USERNAME>`
- All `--key=` args show `--key=<SSH_KEY_PATH>`
- Bearer tokens show `<AUTH_TOKEN>`
- URLs show `<URL>`
- Env var values show `<REDACTED>`

**Step 4: Verify sanitized settings.json**

```bash
cat /tmp/test-export/global/settings.json | jq '.permissions.allow'
```

Expected:
- `Bash(git:*)`, `WebSearch`, etc. preserved
- MCP entries collapsed to `mcp__<server>__exec`, `mcp__<server>__sudo-exec`, etc.
- No duplicates

**Step 5: Verify safe files copied**

```bash
ls /tmp/test-export/global/CLAUDE.md
ls /tmp/test-export/skills/ | head
ls /tmp/test-export/plugins/
ls /tmp/test-export/plans/
ls /tmp/test-export/README.md
```

Expected: All files present.

**Step 6: Verify no sessions or todos**

```bash
find /tmp/test-export -name "*.jsonl" -o -name "*.meta.json" | wc -l
ls /tmp/test-export/todos/ 2>&1
```

Expected: 0 jsonl files, no todos directory.

**Step 7: Verify normal backup still works without --sanitize**

```bash
bash scripts/backup.sh /tmp/test-backup
```

Expected: "No changes detected" — normal backup unaffected.

**Step 8: Clean up and commit**

```bash
rm -rf /tmp/test-backup /tmp/test-export
git add scripts/backup.sh
git commit -m "Finalize sanitized export after E2E testing"
```

---

### Task 8: Update documentation

**Files:**
- Modify: `README.md` (add Sanitized Export section)
- Modify: `CLAUDE.md` (mention --sanitize flag)

**Step 1: Add Sanitized Export section to README.md**

Add after the "Scheduling Automatic Backups" section and before "Security":

```markdown
## Sanitized Export for Sharing

The `--sanitize` flag produces a credential-free copy of your settings, safe for sharing publicly or with teammates.

### Usage

\`\`\`bash
# Run backup and export sanitized copy
bash scripts/backup.sh ~/claude-code-backup --sanitize ~/claude-export

# Share the export directory
cd ~/claude-export
git init && git add -A && git commit -m "Claude Code settings template"
git remote add origin git@github.com:YOUR_USER/claude-code-template.git
git push -u origin main
\`\`\`

### What gets redacted

| Data | Action |
|------|--------|
| MCP server hostnames | Replaced with `<HOSTNAME>` |
| MCP usernames | Replaced with `<USERNAME>` |
| SSH key paths | Replaced with `<SSH_KEY_PATH>` |
| Auth tokens / Bearer tokens | Replaced with `<AUTH_TOKEN>` |
| URLs in MCP args | Replaced with `<URL>` |
| Environment variable values | Replaced with `<REDACTED>` |
| File paths in MCP args | Replaced with `<PATH>` |
| MCP permission names | Server names replaced with `<server>` |
| OAuth account data | Removed entirely |
| App state (counters, caches) | Removed entirely |
| Sessions and todos | Excluded from export |

### What's preserved

- CLAUDE.md and extra context files (as-is)
- Settings structure (plugins, keybindings, preferences)
- MCP server names and types (structure without credentials)
- Skills, plans, commands, plugin registry (as-is)
- Per-project memory (interactive selection)

### Using an export on a new machine

1. Copy the export files into `~/.claude/`
2. Edit `global/claude.json` — replace `<PLACEHOLDER>` values with your server details
3. Edit `global/settings.json` — update `mcp__<server>__*` permission entries
4. Restart Claude Code
```

**Step 2: Update CLAUDE.md to mention --sanitize**

Add to the Key Conventions section:

```markdown
- `--sanitize <output-dir>` flag on backup.sh produces a credential-free export for sharing
```

**Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document sanitized export feature in README and CLAUDE.md"
```

---

### Task 9: Push to GitHub

**Step 1: Push all commits**

```bash
git push origin master
```

**Step 2: Comment on issue #2**

```bash
gh issue comment 2 --repo jtklinger/claude-code-backup-guide --body "Implemented in backup.sh via --sanitize flag. Usage: bash backup.sh [backup-dir] --sanitize <output-dir>"
```
