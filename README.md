# Claude Code Backup & Restore Guide

**Current release: v2.3.0** (see [changelog](#changelog))

A config-driven system for backing up and restoring your complete Claude Code environment — settings, memory, skills, plugins, user-content directories (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks), sessions, subagent transcripts, tool-result payloads, and more.

## Table of Contents

- [Overview](#overview)
- [What to Backup](#what-to-backup)
- [What NOT to Backup](#what-not-to-backup)
- [Quick Start](#quick-start)
- [Detailed Instructions](#detailed-instructions)
- [Scheduling Automatic Backups](#scheduling-automatic-backups)
- [Sanitized Export for Sharing](#sanitized-export-for-sharing)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Changelog](#changelog)
- [Upgrading](#upgrading)
- [Versioning](#versioning)

## Overview

Claude Code stores a rich set of data across your machine: global instructions, per-project memory, installed skills, plugins, saved plans, custom commands, subagents, output styles, rules, hooks, scheduled tasks, session transcripts, subagent transcripts, tool-result payloads, and MCP server configurations. Losing any of these means rebuilding your environment from scratch.

This guide provides three scripts that back up the full Claude Code data model to a private Git repository:

- **`init.sh`** — First-time setup. Scans your projects, generates `backup-config.json`.
- **`backup.sh`** — Config-driven, modular backup with auto-commit and optional auto-push. Fully non-interactive (safe for cron).
- **`restore.sh`** — Interactive restore with per-category prompts (`--yes` for unattended; `--dry-run` to preview without writing).

**Requirements:** bash, git, [jq](https://jqlang.github.io/jq/)

## What to Backup

The v2 system backs up every category of Claude Code data that matters for portability:

| Category | Source Location | Backup Directory | Description |
|----------|----------------|------------------|-------------|
| Global instructions | `~/.claude/CLAUDE.md` | `global/` | Custom instructions for all sessions |
| Extra context files | `~/.claude/*.md` | `global/` | Additional markdown context files |
| Root scripts | `~/.claude/*.{cmd,ps1,js,sh,py}` | `global/` | Custom scripts (MCP helpers, unlock scripts, etc.) — v2.2+ |
| Settings | `~/.claude/settings.json` | `global/` | Basic settings (e.g., alwaysThinkingEnabled) |
| Local settings | `~/.claude/settings.local.json` | `global/` | Permission rules and advanced settings |
| Keybindings | `~/.claude/keybindings.json` | `global/` | Custom key bindings |
| MCP config | `~/.claude.json` | `global/claude.json` | MCP server definitions, OAuth tokens, app state |
| Skills | `~/.claude/skills/` | `skills/` | User-installed skill packages |
| Plugins | `~/.claude/plugins/` | `plugins/` | Plugin registry (installed_plugins.json, blocklist.json, known_marketplaces.json) |
| Plugin data | `~/.claude/plugins/data/` | `plugins/data/` | Persistent plugin state (pdf-viewer, superpowers, etc.) — v2.2+ |
| Plans | `~/.claude/plans/` | `plans/` | Saved implementation plans |
| Custom commands | `~/.claude/commands/` | `commands/` | User-defined slash commands |
| Subagents | `~/.claude/agents/` | `agents/` | Custom subagent definitions (v2.1+) |
| Output styles | `~/.claude/output-styles/` | `output-styles/` | Custom output style definitions (v2.1+) |
| Rules | `~/.claude/rules/` | `rules/` | Topic-scoped instruction files (v2.1+) |
| Hooks | `~/.claude/hooks/` | `hooks/` | Hook scripts referenced by `settings.json` (v2.1+) |
| Scheduled tasks | `~/.claude/scheduled-tasks/` | `scheduled-tasks/` | User-defined scheduled task skills (v2.1+) |
| Todos | `~/.claude/todos/` | `todos/` | Per-session task state |
| Project memory | `~/.claude/projects/<name>/memory/` | `projects/<name>/memory/` | Auto memory files (MEMORY.md, topic files) |
| Session transcripts | `~/.claude/projects/<name>/*.jsonl` | `projects/<name>/sessions/` | Session data for `/resume` support |
| Subagent transcripts | `~/.claude/projects/<name>/<session-uuid>/subagents/` | `projects/<name>/subagents/<session-uuid>/` | Transcripts for subagents spawned by each session (v2.1+) |
| Tool-result payloads | `~/.claude/projects/<name>/<session-uuid>/tool-results/` | `projects/<name>/tool-results/<session-uuid>/` | Large tool-call results referenced by the session transcript (v2.1+) |

The user-content categories marked **v2.1+** (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks) are driven by a shared `USER_CONTENT_DIRS` array in `backup.sh` and `restore.sh`. Adding a new category when Claude Code ships one takes a single-line edit per script.

## What NOT to Backup

These are excluded because they are sensitive, machine-specific, or regenerated automatically:

| File / Directory | Reason to Exclude |
|------------------|-------------------|
| `.credentials.json` | Authentication tokens (regenerated on login) |
| `history.jsonl` | Global prompt history — potentially huge and duplicated by session transcripts |
| `file-history/` | File operation history (machine-specific) |
| `debug/` | Debug logs and temporary data |
| `statsig/`, `telemetry/`, `cache/` | Analytics and cache data |
| `plugins/cache/`, `plugins/marketplaces/` | Re-downloaded on next launch |
| `tasks/` | Runtime state (lock files, high-watermarks) for in-flight background agents |
| `backups/` | Claude Code's own internal session auto-backups |
| `ide/`, `session-env/`, `shell-snapshots/`, `paste-cache/` | Per-session ephemeral state |

## Quick Start

### 1. Clone this guide repository

```bash
git clone https://github.com/jtklinger/claude-code-backup-guide.git
cd claude-code-backup-guide
```

### 2. Create your private backup repository

```bash
# Create a new directory for your backups (separate from this guide repo)
mkdir ~/claude-code-backup
cd ~/claude-code-backup
```

### 3. Run init.sh

The init script scans your `~/.claude/projects/` directory, lets you select which projects to include, and generates `backup-config.json`:

```bash
bash /path/to/claude-code-backup-guide/scripts/init.sh ~/claude-code-backup
```

You will see a numbered list of discovered projects. Type `all`, `none`, or specific numbers separated by spaces.

### 4. Run your first backup

```bash
bash /path/to/claude-code-backup-guide/scripts/backup.sh ~/claude-code-backup
```

The script copies all configured data categories, stages changes, and commits automatically.

### 5. Add a remote and push

```bash
cd ~/claude-code-backup
git remote add origin git@github.com:YOUR_USER/claude-code-backup.git
git push -u origin main
```

### 6. Restore on a new machine

```bash
git clone git@github.com:YOUR_USER/claude-code-backup.git
cd claude-code-backup

# Preview what would change without writing anything (recommended first run
# on a laptop that already has a Claude Code install):
bash /path/to/claude-code-backup-guide/scripts/restore.sh . --dry-run

# Interactive restore (prompts for each category)
bash /path/to/claude-code-backup-guide/scripts/restore.sh .

# Or non-interactive (restore everything)
bash /path/to/claude-code-backup-guide/scripts/restore.sh . --yes
```

`--dry-run` scans every file the restore would touch and classifies it as
**NEW** (destination doesn't exist), **CHANGED** (destination differs), or
**SAME** (identical to backup). Nothing is written. Run this before a real
restore to see exactly which existing files would be overwritten.

## Detailed Instructions

### backup-config.json

The config file lives in the root of your backup repository. It controls what gets backed up:

```json
{
  "version": 1,
  "claude_dir": "~/.claude",
  "include_sessions": true,
  "include_todos": true,
  "projects": [
    "C--Users-me-projects-myproject",
    "C--Users-me-projects-my-app"
  ],
  "git_auto_push": false,
  "git_remote": "origin",
  "git_branch": "main"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | number | Config format version (must be `1`) |
| `claude_dir` | string | Path to Claude Code data directory (`~` is expanded) |
| `include_sessions` | boolean | Whether to back up `.jsonl` session transcripts per project |
| `include_todos` | boolean | Whether to back up per-session todo state |
| `projects` | string[] | List of project directory names from `~/.claude/projects/` |
| `git_auto_push` | boolean | Push to remote after each backup commit |
| `git_remote` | string | Git remote name for auto-push |
| `git_branch` | string | Git branch name for auto-push |

**Project directory names** use Claude Code's encoding scheme where path separators become dashes (e.g., `C--Users-me-projects-myproject` represents `C:/Users/me/projects/myproject`). The `init.sh` script handles this mapping for you.

### Backup repository layout

After running a backup, your repository will look like this:

```
claude-code-backup/
├── backup-config.json
├── .gitignore
├── global/
│   ├── CLAUDE.md
│   ├── settings.json
│   ├── settings.local.json
│   ├── keybindings.json
│   ├── claude.json              # ~/.claude.json (MCP config + OAuth)
│   └── PROJECT-CONTEXT.md       # any extra *.md files
├── skills/
│   └── <skill-packages>/
├── plugins/
│   ├── installed_plugins.json
│   ├── blocklist.json
│   └── known_marketplaces.json
├── plans/
│   └── <plan>.md
├── commands/
│   └── <command>.md
├── agents/                      # v2.1+: custom subagent definitions
├── output-styles/               # v2.1+: custom output style definitions
├── rules/                       # v2.1+: topic-scoped instructions
├── hooks/                       # v2.1+: hook scripts referenced by settings.json
├── scheduled-tasks/             # v2.1+: user-defined scheduled task skills
│   └── <task-name>/
│       └── SKILL.md
├── todos/
│   └── <session-id>.json
└── projects/
    └── C--Users-me-projects-myproject/
        ├── memory/
        │   ├── MEMORY.md
        │   └── <topic>.md
        ├── sessions/
        │   ├── <session-id>.jsonl
        │   └── <session-id>.meta.json
        ├── subagents/                # v2.1+: subagent transcripts, one dir per parent session
        │   └── <session-id>/
        │       ├── agent-<id>.jsonl
        │       └── agent-<id>.meta.json
        └── tool-results/             # v2.1+: large tool-call payloads
            └── <session-id>/
                └── toolu_<id>.txt
```

On restore, the backup's `subagents/<session-id>/` and `tool-results/<session-id>/` directories are replayed back to `~/.claude/projects/<name>/<session-id>/{subagents,tool-results}/` to match Claude Code's on-disk layout.

### Script reference

#### init.sh

```
Usage: bash init.sh [backup-directory]
```

- Creates the backup directory if it does not exist
- Initializes a Git repository
- Copies the `.gitignore` template
- Scans `~/.claude/projects/` and presents an interactive project selector
- Generates `backup-config.json`
- Only needs to be run once (re-run to add new projects)

#### backup.sh

```
Usage: bash backup.sh [backup-directory] [--sanitize <output-directory>]
```

- Reads `backup-config.json` from the backup directory
- Copies all data categories (global settings, MCP config, skills, plugins, user-content dirs, todos, project data including subagent transcripts and tool-result payloads)
- Only copies files that have changed (uses `cmp` for diffing)
- Removes stale files from the backup that no longer exist in the source
- Stages, commits, and optionally pushes
- Fully non-interactive — safe for cron or Task Scheduler
- If no backup-directory argument is provided, assumes the script's parent directory is the backup repo
- `--sanitize <output-directory>` produces a credential-free export in the given directory (see [Sanitized Export](#sanitized-export-for-sharing))

#### restore.sh

```
Usage: bash restore.sh [backup-directory] [--yes] [--dry-run]
```

- Reads `backup-config.json` from the backup directory
- Prompts interactively for each category (global settings, MCP config, skills, plugins, user-content dirs, todos, projects); only prompts for user-content categories that actually have files in the backup
- Creates timestamped backups of existing files before overwriting (e.g. `settings.json.backup.20260421_142301`)
- `--yes` flag skips all prompts and restores everything
- `--dry-run` (aliased `-n`) scans every file and classifies it as **NEW**, **CHANGED**, or **SAME** without writing anything. Implies `--yes`. Use this before a real restore to see exactly which existing files would be overwritten.
- Session files are restored from `sessions/` subdirectory back to the project root (where Claude Code expects them)
- Subagent transcripts and tool-result payloads are restored to `projects/<name>/<session-id>/{subagents,tool-results}/` to match Claude Code's on-disk layout
- Prints a verification summary with file counts and sizes (or a NEW/CHANGED/SAME summary in dry-run mode)

## Scheduling Automatic Backups

Since `backup.sh` is fully non-interactive and auto-commits, it works well as a scheduled task.

### Linux / macOS (cron)

```bash
# Run backup daily at 2:00 AM
crontab -e
# Add this line:
0 2 * * * /path/to/scripts/backup.sh /path/to/claude-code-backup >> /tmp/claude-backup.log 2>&1
```

### Windows (Task Scheduler)

1. Open Task Scheduler
2. Create a new task:
   - **Trigger:** Daily (or at logon, or whatever frequency you prefer)
   - **Action:** Start a program
   - **Program:** `C:\Program Files\Git\bin\bash.exe`
   - **Arguments:** `/path/to/scripts/backup.sh /path/to/claude-code-backup`

### Enabling auto-push

To push to your remote after every backup, edit `backup-config.json`:

```json
{
  "git_auto_push": true,
  "git_remote": "origin",
  "git_branch": "main"
}
```

The backup script will attempt to push after committing. If the push fails, it logs a warning but does not exit with an error.

## Sanitized Export for Sharing

The `--sanitize` flag produces a credential-free copy of your settings, safe for sharing publicly or with teammates.

### Usage

```bash
# Run backup and export sanitized copy
bash scripts/backup.sh ~/claude-code-backup --sanitize ~/claude-export

# Share the export directory
cd ~/claude-export
git init && git add -A && git commit -m "Claude Code settings template"
git remote add origin git@github.com:YOUR_USER/claude-code-template.git
git push -u origin main
```

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
- Skills, plugin registry (as-is)
- User-content directories (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks) — copied as-is. **Review before sharing:** these files may reference your infrastructure, names, or internal systems. The generated `README.md` in the export flags this.
- Per-project memory (interactive selection)

Sessions, todos, subagent transcripts, and tool-result payloads are excluded from the sanitized export (they are conversation-specific and contain content that cannot be safely auto-redacted).

### Using an export on a new machine

1. Copy the export files into `~/.claude/`
2. Edit `global/claude.json` — replace `<PLACEHOLDER>` values with your server details
3. Edit `global/settings.json` — update `mcp__<server>__*` permission entries
4. Restart Claude Code

## Security

### Your backup repository MUST be private

The backup includes `~/.claude.json`, which contains:

- **MCP server configurations** with connection details
- **OAuth tokens** for authenticated MCP servers
- **App state** and other runtime data

It also includes `settings.local.json`, which may contain:

- Approved command patterns that reveal your infrastructure
- File paths and directory structures

**Never use a public repository for your backup.**

### Credential handling

Unlike v1, v2 backs up `~/.claude.json` and `settings.local.json` as-is (no sanitization). This is intentional -- sanitized files lose MCP server definitions and cannot be restored without manual reconfiguration.

The trade-off is clear: **your backup repo is sensitive and must be private.** Treat it like you would a `.env` file or SSH private key.

### If credentials are exposed

If you accidentally push to a public repo or your backup repo is compromised:

1. **Immediately** rotate all OAuth tokens and passwords in your MCP server configurations
2. Re-authenticate with Claude Code
3. Remove the repository from public access
4. Consider using `git filter-branch` or [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) to purge history

### SSH keys for Git access

Use SSH keys (not HTTPS with tokens) for your backup repository remote. This avoids storing additional credentials in your Git config:

```bash
git remote add origin git@github.com:YOUR_USER/claude-code-backup.git
```

## Troubleshooting

### jq not found

**Problem:** `backup.sh` or `restore.sh` exits with "jq is required but not installed"

**Solution:** Install jq for your platform:

```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq

# RHEL/Rocky/Fedora
sudo dnf install jq

# Windows (winget)
winget install jqlang.jq

# Windows (scoop)
scoop install jq
```

### Session files are very large

**Problem:** Backup repository grows quickly due to `.jsonl` session transcripts

**Solution:** Disable session backup if you do not need `/resume` support across machines:

```json
{
  "include_sessions": false
}
```

Or periodically clean old sessions from the backup:

```bash
# Remove session files older than 30 days from the backup
find ~/claude-code-backup/projects/*/sessions/ -name "*.jsonl" -mtime +30 -delete
```

### Memory files not restoring

**Problem:** Per-project memory (MEMORY.md, topic files) not appearing after restore

**Solutions:**

1. Verify the project is listed in `backup-config.json` under `projects`
2. Check that the project directory name matches exactly (case-sensitive)
3. Restart Claude Code after restoring -- memory files are read on startup
4. Verify the files exist: `ls ~/.claude/projects/<project-name>/memory/`

### Settings not applying after restore

**Problem:** Settings do not take effect after running restore.sh

**Solution:**

1. Restart Claude Code completely (quit and relaunch)
2. Check file permissions: `ls -la ~/.claude/`
3. Verify file contents: `cat ~/.claude/settings.json`
4. Check for `.backup.*` files that may indicate the restore created backups of conflicting files

### MCP servers not connecting after restore

**Problem:** MCP servers show as disconnected after restoring `~/.claude.json`

**Solutions:**

1. OAuth tokens in `~/.claude.json` may have expired -- re-authenticate with the affected services
2. Verify network connectivity to the MCP server endpoints
3. Check that any local dependencies (npm packages, binaries) are installed on the new machine
4. Run `claude mcp list` to see the current status

### Backup script reports no changes

**Problem:** `backup.sh` says "No changes detected" even though you changed settings

**Solution:** The script compares files byte-for-byte using `cmp`. If the files are identical, no commit is created. Verify the source files actually changed:

```bash
diff ~/.claude/settings.json ~/claude-code-backup/global/settings.json
```

## FAQ

### Q: How is v2 different from v1? What's new in v2.1?

**A:** v1 backed up only CLAUDE.md, settings.json, settings.local.json, and a text dump of MCP servers. v2 is a config-driven system that backs up the complete Claude Code data model: memory, skills, plugins, plans, commands, keybindings, the full `~/.claude.json`, session transcripts, and todos. It uses three purpose-built scripts (init, backup, restore) instead of manual copy commands.

v2.1 adds scheduled-tasks, subagent transcripts, tool-result payloads, and future-proofs for new user-content categories (agents, output-styles, rules, hooks). It also adds a `--dry-run` flag to `restore.sh` for safely previewing a restore on a machine with an existing Claude Code install. See the [Changelog](#changelog) for the full list.

### Q: Do I need to back up chat history?

**A:** No. Chat history (`history.jsonl`) is excluded intentionally -- it can be hundreds of megabytes and contains the full text of every conversation. If you need to preserve specific conversations, export them individually. Session transcripts (`.jsonl` in project directories) are a different thing and are backed up for `/resume` support.

### Q: Can I share my backup repo publicly?

**A:** No. v2 backs up `~/.claude.json` which contains OAuth tokens and MCP server credentials. Your backup repository must be private. If you want to share your CLAUDE.md or settings as a template, copy those specific files into a separate public repository.

### Q: How often should I back up?

**A:** Set up a cron job or Task Scheduler task to run `backup.sh` daily. The script is idempotent -- if nothing changed, no commit is created. For critical changes (new MCP servers, major CLAUDE.md updates), run a manual backup immediately.

### Q: Can I use this for team settings?

**A:** Partially. You can share CLAUDE.md, plans, commands, and skills through a shared private repository. However, `~/.claude.json` and `settings.local.json` contain per-user credentials and should not be shared. Consider maintaining a team template repo alongside individual backup repos.

### Q: What about project-specific CLAUDE.md files?

**A:** Project-specific `CLAUDE.md` files live in the project's own repository root and should be committed there, not in your settings backup. This guide backs up per-project *memory* (auto-generated context) and *sessions* (for `/resume`), which live under `~/.claude/projects/`.

### Q: Will this work across different OS platforms?

**A:** The settings files themselves are platform-agnostic. However, project directory names encode the full path (e.g., `C--Users-me-projects-myproject`), so a backup from Windows will have Windows-style encoded paths. If restoring on macOS/Linux, you may need to update the `projects` list in `backup-config.json` to match the new machine's paths.

### Q: Can I add new projects after initial setup?

**A:** Yes. Either re-run `init.sh` (it will ask before overwriting the config), or manually edit `backup-config.json` and add the project directory name to the `projects` array. Find directory names with `ls ~/.claude/projects/`.

### Q: What happens to existing files during restore?

**A:** The restore script creates timestamped backups of any existing file before overwriting it (e.g., `settings.json.backup.20260305_140000`). You can always roll back by copying the `.backup.*` file over the restored version.

## Changelog

### v2.3.0 (2026-06-23)

- **New: Windows logging & alerts.** Adds an optional Windows-only observability layer under `scripts/windows/` (`backup-wrapper.ps1`, `backup-watchdog.ps1`, `install.ps1`, `toast.ps1`). The scheduled backup now logs every run to a daily log file **and** the Windows Event Log (source `ClaudeCodeBackup`; IDs 1000 success / 1001 failure / 2000 watchdog), shows a toast on success and failure, and a watchdog warns if no successful backup happens within ~13h. Directly addresses the silent-failure class of bug behind v2.2.0. Setup + details: `scripts/windows/README.md`.
- **Portable `backup.sh` is unchanged** — the Windows layer wraps it; macOS/Linux are unaffected.
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits.

### v2.2.1 (2026-06-23)

- **Critical fix: v2.2.0 shipped a broken `backup.sh`.** The v2.2.0 commit truncated `backup.sh` partway through `main()` — the entire backup body (every `backup_*` call, change detection, commit, and push) was missing — and flipped every script to CRLF line endings. `bash` could not parse the file, so it exited with status 2 and the scheduled backup silently did nothing: no error surfaced, no commit, no push. **Anyone on v2.2.0 should upgrade immediately.**
- **Restored the complete `main()`** — all backup steps (including the new `backup_plugin_data`), the summary, change detection, commit, and push now run as intended.
- **Normalized line endings to LF** across all three scripts and added a `.gitattributes` rule (`*.sh text eol=lf`) so a CRLF flip cannot recur.
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits.

### v2.2.0 (2026-06-23)

- **New: root script backup.** `backup_global_settings()` now captures `~/.claude/*.{cmd,ps1,js,sh,py}` in addition to `*.md` files. Covers MCP helper scripts, unlock scripts, and migration tools users drop in the Claude root.
- **New: plugin data backup.** `backup_plugin_data()` copies `~/.claude/plugins/data/` to `plugins/data/` with a 50 MB size-guard warning. Covers persistent plugin state (pdf-viewer annotations, superpowers preferences, etc.).
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits.

### v2.1.0 (2026-04-21)

- **New backed-up categories:** `~/.claude/scheduled-tasks/` (user-defined scheduled task skills) and per-session nested data — `<session-uuid>/subagents/` (subagent transcripts) and `<session-uuid>/tool-results/` (large tool-call payloads).
- **Future-proofed categories:** `agents/`, `output-styles/`, `rules/`, `hooks/` — covered automatically if/when they appear under `~/.claude/`.
- **New `--dry-run` flag on `restore.sh`:** classifies every file the restore would touch as NEW, CHANGED, or SAME, and writes nothing. Implies `--yes` so the full picture is shown in one pass. Useful before a real restore on a laptop that already has a Claude Code install.
- **Refactor:** user-content directories (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks) are now driven by a shared `USER_CONTENT_DIRS` array in `backup.sh` and `restore.sh`. Adding a new category takes one line per script.
- **Sanitized export:** the generated README now flags user-content directories for review before sharing (they may reference personal infrastructure).
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits.

### v2.0

- Initial config-driven rewrite: three scripts (`init.sh`, `backup.sh`, `restore.sh`) with `backup-config.json`, covering global settings, MCP config, skills, plugins, plans, commands, todos, per-project memory, and session transcripts.
- Added `--sanitize` flag on `backup.sh` to produce credential-free exports.

### v1

- Manual copy-based backup covering only CLAUDE.md, settings.json, settings.local.json, and a text dump of MCP servers.

## Upgrading

### Typical upgrade flow

The scripts run directly out of the guide repo — your scheduled task, cron job, or manual command points at `/path/to/claude-code-backup-guide/scripts/backup.sh`. Upgrading is a two-step `git pull`:

```bash
cd /path/to/claude-code-backup-guide
git pull
```

Confirm the new version on the next run — every script prints its version in the banner:

```
Claude Code Backup Script v2.1.0
==================================
```

Compare the banner against the [Changelog](#changelog) to confirm you picked up the expected release.

### What happens to your existing backup repo

Backups are **additive across releases**. When v2.1 adds new categories (scheduled-tasks, subagents, tool-results, etc.), the first backup run after upgrade will:

- Create the new top-level directories (`scheduled-tasks/`, `agents/`, `output-styles/`, `rules/`, `hooks/`) — only if you have source data for them under `~/.claude/`
- Add `subagents/` and `tool-results/` subdirectories inside each backed-up project
- Commit the additions with the usual `Backup Claude Code settings -- <timestamp>` message

Existing directories (`global/`, `skills/`, `plans/`, `commands/`, `todos/`, `projects/<hash>/memory/`, `projects/<hash>/sessions/`) are untouched. No data is moved or renamed. No config edits required.

Run the backup twice after upgrade — the first run catches up new categories, the second should report "No changes detected", confirming idempotency.

### Version-skew safety

If your backup repo was produced by an older script and you restore with a newer script (or vice versa), both directions work for v2.0 ↔ v2.1:

| Scenario | Behavior |
|----------|----------|
| v2.0 `backup.sh` → v2.1 `restore.sh` | Restore skips new categories (they don't exist in the backup) — no errors. |
| v2.1 `backup.sh` → v2.0 `restore.sh` | Old restore ignores directories it doesn't know about. New categories stay in the backup repo unused until you upgrade the restore side. |

This is safe because v2.1's additions are purely additive. **Future major version bumps may break this** — the changelog entry for any such release will flag the incompatibility explicitly.

### Pinning to a specific version

Once we start tagging releases, you can pin your machine to a known-good version:

```bash
cd /path/to/claude-code-backup-guide
git checkout v2.1.0   # stay on the exact release
# ... later, when you want to upgrade:
git checkout master && git pull
```

Pin if you're running this on multiple machines and want to roll out upgrades deliberately, or if a release causes issues and you want to roll back. Otherwise tracking `master` is fine — the scripts are small enough that breaking changes will be rare and well-documented.

### What to watch for after a major upgrade

A major version bump (v2.x → v3.x) *may* require config migration. The Changelog entry for any such release will spell out:

- Whether `backup-config.json` needs field additions or renames (and provide a migration snippet)
- Whether existing backup directory layouts need to be reorganized (and provide a migration script)
- Whether old backups become unreadable (and how to archive them)

Until then, upgrades within the v2.x line are safe to do automatically — for example, a cron job that runs `git -C /path/to/claude-code-backup-guide pull` once a week before the backup.

## Versioning

This tool uses two distinct version numbers, which move independently:

| Version | Where it lives | Bumped when |
|---------|---------------|-------------|
| **Script version** (`SCRIPT_VERSION="2.1.0"` in each script, printed in the banner) | `scripts/*.sh` | Every release. Follows [SemVer](https://semver.org): major for breaking changes to invocation or output layout, minor for new features, patch for bug fixes. |
| **Config schema version** (`"version": 1` in `backup-config.json`) | `backup-config.json`, enforced at parse time | Only when the config file format changes in a backwards-incompatible way. Currently `1`. |

If you're reporting an issue, include the script ve