# Claude Code Backup v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the v1 backup/restore scripts with a config-driven, modular system that backs up the full Claude Code data model (memory, skills, plugins, MCP config, sessions, plans, commands, todos, keybindings).

**Architecture:** Single `backup.sh` reads `backup-config.json` and calls modular functions per data category. `restore.sh` reverses the process with interactive confirmation. `init.sh` bootstraps first-time setup. All scripts share a common library of helper functions.

**Tech Stack:** Bash, jq (for JSON config parsing), git, cmp (change detection)

---

### Task 1: Update .gitignore for new repo layout

**Files:**
- Modify: `templates/.gitignore`

**Step 1: Rewrite .gitignore**

Replace the existing `.gitignore` template to match the v2 backup repo layout. It must exclude credentials but allow the new directories (global/, skills/, plugins/, plans/, commands/, todos/, projects/).

```gitignore
# Credentials - never commit these standalone
.credentials.json
*.key
*.pem
id_rsa
id_ed25519
id_ecdsa
.env
.env.*

# Temporary files
*.tmp
*.bak
*.swp
*.swo
*~
*.orig
*.rej

# OS files
.DS_Store
Thumbs.db
desktop.ini
$RECYCLE.BIN/

# Editor files
.vscode/
.idea/
*.code-workspace
```

**Step 2: Commit**

```bash
git add templates/.gitignore
git commit -m "Update .gitignore template for v2 backup layout"
```

---

### Task 2: Create backup-config.json template

**Files:**
- Create: `templates/backup-config.json`

**Step 1: Write the config template**

```json
{
  "version": 1,
  "claude_dir": "~/.claude",
  "include_sessions": true,
  "include_todos": true,
  "projects": [],
  "git_auto_push": false,
  "git_remote": "origin",
  "git_branch": "main"
}
```

**Step 2: Commit**

```bash
git add templates/backup-config.json
git commit -m "Add backup-config.json template"
```

---

### Task 3: Write init.sh — first-time setup

**Files:**
- Create: `scripts/init.sh`

**Step 1: Write init.sh**

The script should:
1. Accept an optional backup directory argument (default: current directory)
2. Check that `~/.claude/` exists
3. Initialize git repo if not already initialized
4. Copy `.gitignore` template if no `.gitignore` exists
5. Scan `~/.claude/projects/` and list available projects with their human-readable paths
6. Prompt user to select which projects to include (or all)
7. Generate `backup-config.json` with selected projects and defaults
8. Print next steps (run backup.sh, set up remote, schedule)

Key details:
- Use colored output (GREEN/YELLOW/RED/NC) consistent with v1 style
- Use `set -e` for error handling
- Project names are the directory names under `~/.claude/projects/` (e.g., `C--Users-me-projects-myproject`)
- Convert project hash names to readable paths for display: replace `C--` with `C:/`, `--` with `/`
- Check for `jq` availability and warn if missing (needed by backup.sh)

**Step 2: Commit**

```bash
git add scripts/init.sh
git commit -m "Add init.sh for first-time backup setup"
```

---

### Task 4: Write backup.sh — main backup script

**Files:**
- Replace: `scripts/backup.sh`
- Replace: `scripts/auto-backup.sh` (consolidated into backup.sh)

**Step 1: Write the new backup.sh**

Structure with modular functions:

```bash
#!/bin/bash
# Claude Code Backup Script v2
set -e

# --- Config & Helpers ---

# parse_config() - Read backup-config.json using jq
#   Reads: version, claude_dir, include_sessions, include_todos,
#          projects[], git_auto_push, git_remote, git_branch
#   Expands ~ in claude_dir to $HOME
#   Validates version == 1

# copy_if_changed() - Copy file only if source differs from dest
#   Args: $1=source, $2=dest
#   Uses cmp -s for comparison
#   Creates parent directories as needed
#   Sets CHANGES_MADE=true if copied
#   Handles missing source gracefully (warn, skip)

# sync_directory() - Recursive copy of directory, only changed files
#   Args: $1=source_dir, $2=dest_dir, $3=file_glob (optional, default *)
#   Iterates files matching glob, calls copy_if_changed for each
#   Removes dest files that no longer exist in source
#   Sets CHANGES_MADE=true if any changes

# --- Backup Functions ---

# backup_global_settings()
#   Source: $CLAUDE_DIR/CLAUDE.md → $BACKUP_DIR/global/CLAUDE.md
#   Source: $CLAUDE_DIR/settings.json → $BACKUP_DIR/global/settings.json
#   Source: $CLAUDE_DIR/settings.local.json → $BACKUP_DIR/global/settings.local.json
#   Source: $CLAUDE_DIR/keybindings.json → $BACKUP_DIR/global/keybindings.json (if exists)
#   Source: $CLAUDE_DIR/*.md (all .md files) → $BACKUP_DIR/global/*.md
#   Skip: CLAUDE.md already handled, don't double-copy

# backup_mcp_config()
#   Source: $HOME/.claude.json → $BACKUP_DIR/global/claude.json
#   Note: This is ~/. claude.json NOT ~/.claude/.claude.json

# backup_skills()
#   Source: $CLAUDE_DIR/skills/ → $BACKUP_DIR/skills/
#   Full recursive copy using rsync if available, fallback to cp -r
#   Exclude .git directories inside skills to save space

# backup_plugins()
#   Source: $CLAUDE_DIR/plugins/installed_plugins.json → $BACKUP_DIR/plugins/
#   Source: $CLAUDE_DIR/plugins/blocklist.json → $BACKUP_DIR/plugins/
#   Source: $CLAUDE_DIR/plugins/known_marketplaces.json → $BACKUP_DIR/plugins/
#   Do NOT copy plugins/cache/ or plugins/marketplaces/

# backup_plans()
#   Source: $CLAUDE_DIR/plans/*.md → $BACKUP_DIR/plans/
#   Skip if directory empty or missing

# backup_commands()
#   Source: $CLAUDE_DIR/commands/*.md → $BACKUP_DIR/commands/
#   Skip if directory empty or missing

# backup_todos()
#   Only if include_todos=true in config
#   Source: $CLAUDE_DIR/todos/*.json → $BACKUP_DIR/todos/
#   Sync (remove deleted todos from backup too)

# backup_projects()
#   For each project in config.projects[]:
#     Warn if $CLAUDE_DIR/projects/$project/ doesn't exist, skip
#     Copy memory/: $CLAUDE_DIR/projects/$project/memory/ → $BACKUP_DIR/projects/$project/memory/
#     If include_sessions=true:
#       Copy *.jsonl: $CLAUDE_DIR/projects/$project/*.jsonl → $BACKUP_DIR/projects/$project/sessions/
#       Copy *.meta.json alongside session files

# --- Main Flow ---
# 1. Determine BACKUP_DIR from $1 or script's parent directory
# 2. parse_config
# 3. Call each backup function, log progress
# 4. Print security info summary (count of files backed up per category)
# 5. Git add all, check for staged changes
# 6. If changes: commit with "Backup Claude Code settings - YYYY-MM-DD HH:MM:SS"
# 7. If git_auto_push: push to configured remote/branch
# 8. Print summary with last commit hash
```

Key details:
- `jq` is required — script exits with clear error if missing
- The script is fully non-interactive (safe for cron)
- BACKUP_DIR defaults to the directory containing the script's parent (i.e., the repo root)
- Colored output with LOG_PREFIX timestamp for cron-friendliness
- Each function logs what it does with counts
- `git add` uses explicit paths per category, not `git add .`

**Step 2: Make executable**

```bash
chmod +x scripts/backup.sh
```

**Step 3: Commit**

```bash
git add scripts/backup.sh
git commit -m "Rewrite backup.sh as config-driven modular v2"
```

---

### Task 5: Write restore.sh — restore script

**Files:**
- Replace: `scripts/restore.sh`

**Step 1: Write the new restore.sh**

Structure:

```bash
#!/bin/bash
# Claude Code Restore Script v2
set -e

# --- Helpers ---
# parse_config() - same as backup.sh (or source a shared lib)
# backup_existing() - backup file with .backup.<timestamp> before overwrite
# prompt_restore() - ask user Y/n before restoring a category
#   Args: $1=category_name
#   In non-interactive mode (--yes flag), always returns true

# --- Restore Functions ---

# restore_global_settings()
#   $BACKUP_DIR/global/CLAUDE.md → $CLAUDE_DIR/CLAUDE.md
#   $BACKUP_DIR/global/settings.json → $CLAUDE_DIR/settings.json
#   $BACKUP_DIR/global/settings.local.json → $CLAUDE_DIR/settings.local.json
#   $BACKUP_DIR/global/keybindings.json → $CLAUDE_DIR/keybindings.json
#   $BACKUP_DIR/global/*.md → $CLAUDE_DIR/*.md (extra context files)
#   Each file: backup_existing() then copy

# restore_mcp_config()
#   $BACKUP_DIR/global/claude.json → $HOME/.claude.json
#   WARN: this overwrites OAuth tokens, may need to re-authenticate

# restore_skills()
#   $BACKUP_DIR/skills/ → $CLAUDE_DIR/skills/
#   Recursive copy

# restore_plugins()
#   $BACKUP_DIR/plugins/*.json → $CLAUDE_DIR/plugins/*.json
#   Note: plugins will re-download their cache on next launch

# restore_plans()
#   $BACKUP_DIR/plans/ → $CLAUDE_DIR/plans/

# restore_commands()
#   $BACKUP_DIR/commands/ → $CLAUDE_DIR/commands/

# restore_todos()
#   $BACKUP_DIR/todos/ → $CLAUDE_DIR/todos/

# restore_projects()
#   For each project dir in $BACKUP_DIR/projects/:
#     Create $CLAUDE_DIR/projects/$project/ if needed
#     Copy memory/ back
#     If sessions/ exists, copy *.jsonl back to project root
#     Copy *.meta.json alongside sessions

# --- Main Flow ---
# 1. Parse args: BACKUP_DIR, --yes flag
# 2. parse_config
# 3. Create $CLAUDE_DIR if missing
# 4. For each category: prompt_restore() then restore function
# 5. Print verification summary (list restored files/dirs)
# 6. Print next steps (restart Claude Code, re-authenticate if needed)
```

Key details:
- Interactive by default (prompt per category), `--yes` flag for automated restore
- Always backs up existing files before overwriting
- Warns about OAuth token overwrite when restoring claude.json
- Session .jsonl files restore to the project directory root (not a sessions/ subdirectory) since that's where Claude Code reads them from

**Step 2: Commit**

```bash
git add scripts/restore.sh
git commit -m "Rewrite restore.sh as config-driven v2 with per-category prompts"
```

---

### Task 6: Remove obsolete files

**Files:**
- Delete: `scripts/auto-backup.sh` (functionality merged into backup.sh)
- Delete: `scripts/restore-mcp-template.sh` (replaced by full claude.json backup/restore)

**Step 1: Remove files**

```bash
git rm scripts/auto-backup.sh scripts/restore-mcp-template.sh
```

**Step 2: Commit**

```bash
git commit -m "Remove v1 scripts superseded by v2 backup/restore"
```

---

### Task 7: Update README.md

**Files:**
- Modify: `README.md`

**Step 1: Rewrite README.md**

Major sections to update:

1. **Overview** — Mention memory, skills, plugins, MCP config, sessions as backed-up data
2. **What to Backup** — Complete table matching the design doc's data model
3. **What NOT to Backup** — Updated exclusion list
4. **Quick Start** — New flow: clone guide repo → run init.sh → edit config → run backup.sh → push
5. **Detailed Instructions** — Remove old manual steps, document:
   - `init.sh` usage and project selection
   - `backup-config.json` format and all options
   - `backup.sh` behavior (non-interactive, change detection, auto-commit/push)
   - `restore.sh` behavior (interactive prompts, --yes flag, per-category restore)
6. **Scheduling** — Cron and Windows Task Scheduler examples with the new script
7. **Security** — Updated: claude.json contains OAuth tokens, repo MUST be private
8. **Troubleshooting** — Add: jq not installed, large session files, memory not restoring
9. **Future Roadmap** — GUI front-end, S3/Backblaze target

Remove:
- Old MCP restore template references
- Old sanitization instructions (we back up as-is now)
- References to `auto-backup.sh` (merged)

**Step 2: Commit**

```bash
git add README.md
git commit -m "Rewrite README for v2 backup system"
```

---

### Task 8: Update QUICKSTART.md

**Files:**
- Modify: `QUICKSTART.md`

**Step 1: Rewrite for v2 flow**

Simplified quick start:

```bash
# 1. Create private GitHub repo
gh repo create claude-code-settings-backup --private --clone
cd claude-code-settings-backup

# 2. Download and run init script
curl -O https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/init.sh
bash init.sh .

# 3. Download backup script and run first backup
curl -O https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/backup.sh
curl -O https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/restore.sh
bash scripts/backup.sh .

# 4. Push
git push -u origin main
```

What gets backed up (updated list), restore steps, scheduling one-liner.

**Step 2: Commit**

```bash
git add QUICKSTART.md
git commit -m "Update QUICKSTART for v2 backup flow"
```

---

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update project description**

Reflect the v2 architecture: config-driven, modular functions, jq dependency, new repo layout. Update testing instructions to cover init.sh and config parsing.

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md for v2 architecture"
```

---

### Task 10: End-to-end manual test

**Step 1: Test init.sh**

```bash
mkdir /tmp/test-backup-v2
bash scripts/init.sh /tmp/test-backup-v2
# Verify: backup-config.json created, .gitignore created, git initialized
cat /tmp/test-backup-v2/backup-config.json
```

**Step 2: Test backup.sh**

```bash
bash scripts/backup.sh /tmp/test-backup-v2
# Verify: directories created (global/, skills/, plugins/, plans/, projects/)
# Verify: files copied correctly
ls -R /tmp/test-backup-v2/global/
ls -R /tmp/test-backup-v2/skills/
ls -R /tmp/test-backup-v2/projects/
# Verify: git commit was created
cd /tmp/test-backup-v2 && git log --oneline -1
```

**Step 3: Test idempotency**

```bash
bash scripts/backup.sh /tmp/test-backup-v2
# Verify: "No changes detected" message, no new commit
cd /tmp/test-backup-v2 && git log --oneline -2
```

**Step 4: Test restore.sh**

```bash
# Simulate by renaming a memory file, then restoring
bash scripts/restore.sh /tmp/test-backup-v2 --yes
# Verify: files restored, .backup files created
```

**Step 5: Clean up**

```bash
rm -rf /tmp/test-backup-v2
```

**Step 6: Final commit if any fixes needed**

```bash
git add -A
git commit -m "Fix issues found during end-to-end testing"
```
