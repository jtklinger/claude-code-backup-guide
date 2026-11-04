# Claude Code Backup & Restore Guide

**Current release: v2.5.1** (see [changelog](#changelog))

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
- [Restoring to a Different Machine](#restoring-to-a-different-machine)
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

**Requirements:** bash 4+, git, [jq](https://jqlang.github.io/jq/). The scripts use associative arrays, so bash 4 or newer is required — stock macOS ships bash 3.2, so on macOS run `brew install bash` and invoke with the newer bash (e.g. `/opt/homebrew/bin/bash`). Windows Git Bash and modern Linux already ship bash 4+.

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
  "projects": ["*"],
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
| `projects` | string[] | Patterns matched against directory names in `~/.claude/projects/` (see below) |
| `git_auto_push` | boolean | Push to remote after each backup commit |
| `git_remote` | string | Git remote name for auto-push |
| `git_branch` | string | Git branch name for auto-push |

**Project directory names** use Claude Code's encoding scheme where path separators become dashes (e.g., `C--Users-me-projects-myproject` represents `C:/Users/me/projects/myproject`). The `init.sh` script handles this mapping for you.

**The `projects` field is pattern-based, not a fixed list:**

- `["*"]` (the default, recommended) — discover every directory under `~/.claude/projects/` at backup time. This automatically picks up new projects **and** git worktree sessions (Claude Code creates a new project slug like `C--Users-me-projects-myproject--claude-worktrees-<name>-<hash>` for every worktree you open), which a fixed list can never keep up with since worktree names are randomly generated per-worktree.
- Exact slugs (e.g. `"C--Users-me-projects-my-app"`) — back up only that one project, no worktrees, no future additions. Use this to intentionally scope down (e.g. exclude a project with sensitive session content).
- Prefix globs (e.g. `"C--Users-me-projects-myproject*"`) — back up a project **and** all of its worktree sessions, without picking up unrelated projects. Bash glob syntax (`*`, `?`, `[...]`).
- `[]` (empty) — back up no project/session data at all. This is a deliberate opt-out, not the same as "not configured."

Mixing is fine — e.g. `["*"]` for everything, or `["C--Users-me-projects-myproject*", "C--Users-me-projects-my-app"]` to scope to two specific things.

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
│   ├── unlock-secrets.ps1            # v2.2+: custom root scripts (*.cmd/*.ps1/*.js/*.sh/*.py)
│   └── PROJECT-CONTEXT.md       # any extra *.md files
├── skills/
│   └── <skill-packages>/
├── plugins/
│   ├── installed_plugins.json
│   ├── blocklist.json
│   ├── known_marketplaces.json
│   └── data/                    # v2.2+: persistent plugin state
│       └── <plugin-name>/
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
Usage: bash backup.sh [backup-directory] [--fast] [--status] [--sanitize <output-directory>]
```

- Reads `backup-config.json` from the backup directory
- Copies all data categories (global settings, MCP config, skills, plugins, user-content dirs, todos, project data including subagent transcripts and tool-result payloads)
- Only copies files that have changed — byte-exact (`cmp`) by default, or size + mtime with `--fast`
- Removes stale files from the backup that no longer exist in the source
- Stages, commits, and optionally pushes
- Fully non-interactive — safe for cron or Task Scheduler
- If no backup-directory argument is provided, assumes the script's parent directory is the backup repo
- `--sanitize <output-directory>` produces a credential-free export in the given directory (see [Sanitized Export](#sanitized-export-for-sharing))
- `--fast` detects changes by **size + modified-time** instead of reading every byte — much faster over a large, mostly-unchanged corpus (session transcripts). Opt-in; the default stays byte-exact. Trade-off: a content change that preserves *both* size and mtime isn't detected (safe for Claude's append-only session/todo files). The first `--fast` run re-copies once to stamp preserved mtimes, then subsequent runs are fast.
- `--status` prints a health readout (last commit, total commits, remote sync, working-tree + `.git` size) for the backup directory and exits without backing up

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

The backup script attempts to push after committing. The local commit always succeeds first; if the push then fails **and `git_auto_push` is enabled**, the script logs the error and exits non-zero (so a scheduled run reports failure and the Windows watchdog notices, rather than toasting success while the off-machine copy silently ages out of sync). The commit is preserved and the next run retries the push. If `git_auto_push` is `false`, no push is attempted and the run exits 0 after committing locally.

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

1. Verify the project would be captured by `backup-config.json`'s `projects` patterns — the default `["*"]` backs up every project, so no edit is needed unless you've scoped it down to specific slugs/globs
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

## Restoring to a Different Machine

Field notes from a real restore (2026-11-03): one machine's backup restored onto a freshly
installed laptop, which then became a backup member in its own right. The scripts did what
they say; everything that bit was *around* them. Recorded here so the next restore goes
faster, and as the to-do list for the next release.

### The sequence that worked

1. **Pre-flight on the new machine.** `gh auth login`, then `gh auth setup-git` so HTTPS
   pushes work; `git config --global user.name` / `user.email` (a fresh box has none —
   the first commit fails with "empty ident name"); confirm `jq` and bash 4+. If you are
   not sure of the backup repo's exact name, `gh repo list <user> | grep backup` — a
   transposed word costs a confusing "not found".
2. **Clone the guide and the backup repo side by side.**
3. **Clone whatever your global `CLAUDE.md` imports first.** If it `@`-imports a file
   outside `~/.claude` (a shared-config repo, say), `restore.sh` restores the import
   *line*, not its target. Put the target in place before the restore so the first
   session after it loads correctly.
4. **`restore.sh <backup> --dry-run`** and read the CHANGED list. Note whether
   `~/.claude.json` is in it.
5. **Interactive restore.** Answer **no** to *MCP config* if the new machine already has a
   working login — that category overwrites the whole of `~/.claude.json`, not just the
   server list. Re-add the servers afterwards (by hand, or with your own sync tooling).
6. **Rewrite the machine-specific parts of the restored `CLAUDE.md`** — host facts,
   installed tooling, SSH fleet. They describe the *source* machine and every future
   session on the new one will read them as true.
7. **Create a new private backup repo for this machine before enabling any schedule.**
   Point `backup-config.json`, and any timer or task that wraps `backup.sh`, at it. See
   the first lesson below for why this is step 7 and not step 12.
8. **First backup by hand**, confirm the push landed, then enable the schedule.
9. **Delete the `.backup.<timestamp>` copies** the restore left behind (see lesson 4).

### Lessons learned

1. **A restored machine inherits the source machine's backup target.** The restored
   settings, and any runner script or timer unit you reinstall, still point at the
   *source* machine's backup repo. `backup.sh` never pulls before pushing, and its
   top-level directories (`global/`, `skills/`, `plugins/`, `todos/`) are not namespaced
   per machine, so the new machine's first scheduled run would overwrite the source
   machine's disaster-recovery copy. This was caught 26 minutes before the first run.
   One backup repo per machine, created *before* the timer goes live.
2. **A restore copies the machine layer too.** Host facts in `CLAUDE.md`, per-project
   memory, session history — all of it describes the source machine. The scripts cannot
   tell the two layers apart; you have to.
3. **Auth is the first blocker, not the scripts.** An expired `gh` keyring token and no
   SSH keys stopped the clone before anything else ran. Nothing in the restore path
   checks for this up front.
4. **SAME files still get `.backup.*` copies.** `restore.sh` backs up every existing
   destination file before writing, even when `cmp` already proved it identical. One
   restore left 230 such copies under `~/.claude/skills/`, and the next scheduled backup
   swept them all into the repo.
5. **The dry run earned its keep.** It was the only thing that made the
   `~/.claude.json` overwrite visible before it happened. Always run it first on a
   machine that already has a Claude Code login.
6. **The restore is not self-contained when `CLAUDE.md` imports from outside
   `~/.claude`.** The import line comes back; the file it points to does not. A missing
   import target fails silently at load time.
7. **The restore summary over-reports.** The verification block lists every `*.md` and
   `*.json` in the `~/.claude` root — including files the restore never touched — so it
   is not a record of what was written.
8. **The toolchain is not in the backup.** Node version, `rg`, `gcloud`, SSH config and
   keys: none of it comes back, but the restored `CLAUDE.md` and `settings.json` assume
   it is there.
9. **MCP servers resolved by bare package name can rot.** One `npx -y <name>` server
   resolved to a release that no longer ships a Linux binary. Pin versions in anything
   you intend to restore.

### Cross-OS restores

Everything above assumed the same OS on both ends. A Windows backup restored onto Linux
or macOS (or the reverse) adds a second class of problem: the scripts copy bytes
faithfully, and the bytes encode the source OS. From a real Windows-made backup:

| What | In the backup | On the other OS |
|------|---------------|-----------------|
| Project slugs | `C--Users-me-projects-foo` | `restore.sh` writes them verbatim. Claude Code on Linux looks for `-home-me-projects-foo`, so memory and sessions are on disk but never loaded. `backup-config.json`'s `projects` list does **not** help — restore ignores it. |
| `~/.claude.json` | `projects` map keyed by `C:/Users/...`; `mcpServers` wrapped in `cmd /c npx` | Per-project trust for directories that do not exist; MCP definitions that cannot start. A whole-file MCP restore is wrong on arrival. |
| `settings.json` | `Bash(powershell.exe:*)`, `Bash(ipconfig:*)`, `env.CLAUDE_CODE_PLUGIN_DIRS` with `C:\...` and `;` separators, hooks that call Windows tools | Dead permission entries, a broken plugin-dir path, hooks that fail on every tool call. **Not** platform-agnostic, whatever the FAQ used to say. |
| `plugins/installed_plugins.json` | `installPath` of `C:\Users\me\.claude\plugins\cache\...` | Plugins re-download their cache, but the registry still points at the old path. |
| Root scripts | `*.cmd`, `*.ps1` (and `*.sh` the other way) | Restored, inert. |
| Shell scripts under `skills/` | Git on Windows does not track the execute bit | Come back on Linux without `+x`. |
| Line endings | Depends on the Windows side's `core.autocrlf` (this backup: none) | Check with `file`; CRLF in a shell script breaks it. |
| Long paths (Linux → Windows) | Slugs that embed two UUIDs | v2.5.1 fixed `MAX_PATH` for the backup *repo*; the restore *destination* under `~/.claude` can still exceed it. |
| Session transcripts | `"cwd":"C:\\Users\\..."` inside the `.jsonl` | Harmless — informational once the slug directory is remapped. |

What *is* portable: memory contents, session content (once the slug is renamed), skills,
plans, commands, agents, output-styles, rules, the preferences half of `CLAUDE.md`, and
the OS-neutral parts of `settings.json` (deny list, `autoMode` policy, `modelSettings`,
`enabledPlugins`). That split — portable layer versus machine layer — is what makes
cross-OS restores tractable; keep the two in separate files if you run more than one OS.

Sequence that works today, with the scripts as they are:

1. Restore **only** skills, the user-content directories, and projects. Answer no to
   global settings, MCP config, and plugins.
2. Rename the project slugs you want Claude Code to find. For the workspace root only:

   ```bash
   cd ~/.claude/projects
   for d in C--Users-me-projects*; do mv "$d" "${d/C--Users-me-projects/-home-me-projects}"; done
   ```

   Slugs with no counterpart on the new OS (`AppData`, scratch workspaces) stay as they
   are; they are inert.
3. Rebuild `settings.json` by hand from the backup's copy: keep what names a
   cross-platform tool, drop anything naming an `.exe`, `.cmd`, `.ps1`, a drive letter,
   or a `;`-separated path list.
4. Add MCP servers by hand in the native form (`npx` on POSIX, `cmd /c npx` on Windows).
5. Let plugins reinstall: `claude plugin install <name> --scope user` per enabled plugin.
6. `chmod +x` any restored `*.sh` / `*.py` that needs it; check `file` for CRLF.

### Proposed improvements (not yet implemented)

- **`backup.sh`: write a `backup-manifest.json`** (hostname, OS, Claude Code version,
  script version, timestamp) on every run. `restore.sh` prints it and warns when the
  hostname differs from the machine it is running on.
- **`backup-config.json`: optional `"host"` field.** When set, `backup.sh` refuses to run
  on a machine whose `hostname -s` differs, unless `--force`. Closes lesson 1 at the
  source instead of relying on someone noticing.
- **`restore.sh`: skip `backup_existing` when the file is already identical.** No
  `.backup.*` clutter for SAME files.
- **`restore.sh`: per-category skip flags** (e.g. `--skip mcp,todos`) so an unattended
  restore can leave `~/.claude.json` alone without piping prompt answers.
- **`restore.sh`: MCP merge mode.** Merge the backup's `mcpServers` into the existing
  `~/.claude.json` instead of replacing the file.
- **`restore.sh`: list only what it wrote** in the verification summary.
- **`restore.sh`: after restoring `CLAUDE.md`, resolve its `@`-imports** and report any
  target that does not exist.
- **README: a new-machine pre-flight checklist** (auth, git identity, credential helper,
  shared-config repo) ahead of the Quick Start restore step.

Cross-OS specifically:

- **`restore.sh --remap <from>=<to>`** — rename project slugs on the way in
  (`C--Users-me-projects=-home-me-projects`), and rewrite the matching `projects` keys if
  `~/.claude.json` is merged rather than replaced. The single change that makes memory
  and sessions usable across OSes.
- **Warn on slug-scheme mismatch.** A backup whose slugs start with `<letter>--` restored
  on POSIX (or the reverse) should say so before the first prompt.
- **`settings.json` merge mode with OS filtering** — when restoring to POSIX, drop (and
  list) entries naming `.exe`/`.cmd`/`.ps1`/drive-letter paths; the reverse for Windows.
- **Execute bits.** Record the mode of `*.sh`/`*.py` at backup time, or have `restore.sh`
  set `+x` on restored scripts by extension.
- **Restore-side long-path check on Windows** — refuse, or warn per file, when a
  destination path would exceed `MAX_PATH`.

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

**A:** Partly. Skills, user-content directories, memory and session *content* are portable. Project directory names encode the full source path (e.g., `C--Users-me-projects-myproject`) and `restore.sh` writes them verbatim, so on another OS they must be renamed before Claude Code will load them — editing `backup-config.json`'s `projects` list does not help, restore ignores it. `settings.json`, `~/.claude.json` and the plugin registry carry OS-specific commands and absolute paths and should be rebuilt rather than restored. See [Cross-OS restores](#cross-os-restores).

### Q: Can I add new projects after initial setup?

**A:** With the default `projects: ["*"]` config (what `init.sh`'s "all" selection now writes), **no action is needed** — new projects and worktree sessions are discovered automatically on the next backup. You only need to edit `backup-config.json` if you've deliberately scoped `projects` down to specific slugs or prefix globs; in that case add another pattern to the `projects` array (find directory names with `ls ~/.claude/projects/`), or re-run `init.sh` (it will ask before overwriting the config).

### Q: What happens to existing files during restore?

**A:** The restore script creates timestamped backups of any existing file before overwriting it (e.g., `settings.json.backup.20260305_140000`). You can always roll back by copying the `.backup.*` file over the restored version. Note that this currently happens even for files the dry run classifies as SAME, so a restore onto a machine that already matches the backup leaves many identical `.backup.*` copies behind — see [Restoring to a Different Machine](#restoring-to-a-different-machine).

## Changelog

### Unreleased

- **Docs:** new [Restoring to a Different Machine](#restoring-to-a-different-machine) section — the sequence that worked on a real cross-machine restore, nine lessons learned, a [Cross-OS restores](#cross-os-restores) subsection built from inspecting a real Windows-made backup, and the list of script improvements they point to. The cross-platform FAQ answer is corrected: the settings files are not platform-agnostic. No script changes.

### v2.5.1 (2026-09-22)

- **Fixed: Windows backups failed outright once any project path exceeded `MAX_PATH` (260).** Claude Code's auto-generated project slugs (a scratch-workspace slug embeds two UUIDs) can push `projects/<slug>/sessions/<uuid>.jsonl` past the limit, and without `core.longpaths` git aborts the whole `git add` with `Filename too long` — every run, until the repo is configured by hand. Became reachable in v2.5.0 once `["*"]` started discovering every project directory. `init.sh` now sets `core.longpaths true` on new Windows backup repos, and `backup.sh` sets it on existing ones the next time it runs (repo-scoped, idempotent, logged when it fires). macOS and Linux are untouched.
- **Fixed: the Windows scheduled backup could silently never run on a laptop.** `install.ps1` set the tasks' *actions* but never their *conditions*, so both tasks inherited Task Scheduler's defaults: `DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` on (a run starting on battery is refused — surfacing only as `LastTaskResult` `0x800710E0`, with no log file written — and unplugging mid-run kills it) and `StartWhenAvailable` off (a slot missed while the machine was off or asleep is never retried). These compound: the machine sleeps through a scheduled slot, nothing catches up, and the next attempt after resume is refused for being on battery — so backups can stop for days while each individual run still looks fine. `install.ps1` now clears all three on both the backup and watchdog tasks (no-ops on a desktop), and `scripts/windows/README.md` documents them with a copy-paste fix for hand-created tasks.
- **Fixed: the watchdog could report a permanent false alarm.** `install.ps1` did not pass `-BackupDir` to the watchdog task, leaving it on its own default. If that default did not match the wrapper's `-BackupDir`, the watchdog read a `last-run.json` that does not exist and warned *"no successful backup since never"* on every 4-hourly check — regardless of whether backups were succeeding — burying genuine alerts in constant noise. `install.ps1` now passes `-BackupDir` explicitly.
- **Cleanup:** removed a dead unused-count capture in `backup_todos()` (mirrors the `mem_count` cleanup done in v2.5.0; no behavior change).
- **Portable default:** the Windows scripts' `BackupDir` default is now `$env:USERPROFILE\claude-code-backup` instead of a hardcoded user path — works for any user out of the box. The scheduled task still passes `-BackupDir` explicitly, so existing installs are unaffected.

### v2.5.0 (2026-07-07)

- **Changed: `projects` is now pattern-based, with dynamic discovery.** Previously `backup-config.json`'s `projects` array was a fixed allowlist of exact directory names under `~/.claude/projects/` — anything not literally listed was silently skipped. This missed every git worktree session (Claude Code creates a new, randomly-named project slug per worktree, e.g. `C--Users-me-projects-myproject--claude-worktrees-<name>-<hash>`), since a static list can never keep up with names generated after the config was written. `projects` entries are now matched as bash glob patterns against `~/.claude/projects/` at backup time: `["*"]` (the new recommended default) discovers everything, including future projects and worktrees; a prefix glob like `"C--Users-me-projects-myproject*"` scopes to one project plus all its worktrees; exact slugs still work unchanged for users who deliberately scope down; `[]` still means "back up no project/session data" (unchanged opt-out).
- **`init.sh`'s "all" selection** now writes `["*"]` instead of a point-in-time snapshot list, so a fresh setup stays complete as new projects and worktrees appear.
- **Pre-release hardening pass** (same release, no schema change):
  - **`--sanitize` credential redaction hardened.** `Authorization: Bearer` tokens are now redacted in both `--header <value>` and `--header=<value>` forms and case-insensitively (previously the common `Authorization:` capitalization leaked through in cleartext). `settings.json`'s top-level `env` values are now redacted, arbitrary `plugins/data/` state is excluded from exports, and the export README flags non-MCP `Bash(...)` allow-rules (e.g. `Bash(ssh <host>:*)`) for manual review since only `mcp__…` permission names are auto-redacted.
  - **No more silent backups.** A failed `git add` (e.g. a stale `.git/index.lock`) now aborts loudly with a non-zero exit instead of being swallowed and reported as "No changes detected."
  - **Backups are now self-sufficient.** `backup.sh` stages `backup-config.json` and `.gitignore`, so a fresh clone is a valid, restorable backup repo (previously a disaster-recovery clone hard-failed with "Config file not found").
  - **Restore fidelity.** `restore.sh` now restores custom root scripts (`*.cmd/*.ps1/*.js/*.sh/*.py`) and `plugins/data/`, both of which were backed up but never written back. `restore.sh --dry-run` no longer creates empty directories — it truly writes nothing.
  - **Config edge cases.** An absent `projects` key now defaults to `["*"]` (back up everything) like every other field's default, rather than backing up nothing; patterns containing spaces are handled as single literal tokens.
  - **Push failures surface.** When `git_auto_push` is enabled, a push failure now exits non-zero (the local commit is preserved) so scheduled-run status and the Windows watchdog reflect that the off-machine copy is out of sync.
  - **Requires bash 4+** explicitly, with a clear up-front error. Stock macOS bash 3.2 was never actually supported (associative arrays); on macOS run `brew install bash`.
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits; a config with an explicit list of exact slugs behaves exactly as before.

### v2.4.0 (2026-06-28)

- **New: `--fast` change detection on `backup.sh`.** Detects changes by size + mtime (one `stat` per file, no byte read) instead of a full byte-compare. Far less I/O over a large, mostly-unchanged corpus — on the maintainer's session-heavy repo a no-op run is ~2× faster. Opt-in; the default stays byte-exact (`cmp`). Trade-off: a content change that preserves *both* size and mtime is not detected, which is safe for Claude's append-only session/todo files. The first `--fast` run after upgrading re-copies once to stamp preserved mtimes, then settles into fast no-ops.
- **New: `-Fast` / `-Silent` switches on the Windows layer.** `install.ps1 -Fast` bakes `--fast` into the scheduled backup task; `install.ps1 -Silent` runs the backup + watchdog with a hidden window (no console pop-up during the multi-minute run) while toasts still appear. `backup-wrapper.ps1` and `backup-watchdog.ps1` gained matching `-Fast`/`-Silent` parameters.
- **New: `backup.sh --status`.** Prints a health readout — last commit, total commits, remote-sync state, and working-tree + `.git` sizes — then exits without backing up. A quick "is my backup healthy?" check.
- **Improved: failure toasts name the cause.** A failed run's toast now includes the last error line from the backup output (ANSI-stripped), so you see *why* it failed at a glance instead of just an exit code.
- **New: CI lint guard.** A GitHub Actions workflow (`.github/workflows/lint.yml`) runs `bash -n` on every script on push/PR — the hard gate that would have caught the v2.2.0 truncation — plus ShellCheck and PSScriptAnalyzer as advisory linters.
- **No config schema changes** — existing `backup-config.json` (version `1`) continues to work without edits.

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

Upgrades within v2.x are **additive and backward-compatible** — no `backup-config.json` changes, and a backup made with an older v2.x restores fine with a newer script (and vice-versa).

### Typical upgrade flow

**1. Pull the new scripts.** The scripts run directly out of the guide repo — your scheduled task, cron job, or manual command points at `/path/to/claude-code-backup-guide/scripts/backup.sh`, which is read fresh on each run, so jobs pick up the new version automatically:

```bash
cd /path/to/claude-code-backup-guide
git pull
```

**2. (Windows only) Re-run the installer to adopt new task options.** If you use the Windows observability layer and want new switches baked into the scheduled task (e.g. `-Fast` / `-Silent`), re-run the **elevated** installer — it's idempotent and updates the existing tasks in place (triggers and principal preserved):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "...\scripts\windows\install.ps1" -Fast -Silent
```

Skip this if your upgrade only changed `backup.sh` behavior, not the task wiring.

**3. Verify.** Every script prints its version in the banner; confirm the new run via `--status`:

```bash
bash scripts/backup.sh /path/to/your-backup --status    # version, last commit, sync state, sizes
```

```
Claude Code Backup Script v2.5.1
==================================
```

Compare the banner against the [Changelog](#changelog) to confirm you picked up the expected release. On Windows, also confirm the next scheduled run writes a `1000` event: `Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 1`.

> **First `--fast` run after upgrading:** if your backup repo was last written by byte-exact runs, the first `--fast` run re-stamps every file's mtime once (so it isn't faster *that* run); subsequent runs get the speedup.

### What happens to your existing backup repo

Backups are **additive across releases**. When a release adds new categories, the first backup run after upgrade creates the new directories (only if you have matching source data under `~/.claude/`) and commits them with the usual `Backup Claude Code settings -- <timestamp>` message. Existing directories are untouched — no data is moved or renamed, no config edits required. Run the backup twice after upgrade: the first run catches up new categories, the second should report "No changes detected", confirming idempotency.

### Version-skew safety

Within the v2.x line, a backup produced by one script version restores with any other v2.x script in both directions — a newer restore skips categories a newer backup would have added but an older one didn't, and an older restore ignores directories it doesn't recognize (they stay in the backup unused until you upgrade). This is safe because v2.x additions are purely additive. **Future major version bumps may break this** — the changelog entry for any such release will flag the incompatibility explicitly.

### Pinning to a specific version

Releases are tagged, so you can pin a machine to a known-good version:

```bash
cd /path/to/claude-code-backup-guide
git checkout v2.5.1   # stay on the exact release
# ... later, when you want to upgrade:
git checkout main && git pull
```

Pin if you're rolling out upgrades deliberately across multiple machines, or want to roll back a release that caused issues. Otherwise tracking `main` is fine — the scripts are small and breaking changes are rare and well-documented.

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
| **Script version** (`SCRIPT_VERSION="2.5.1"` in each script, printed in the banner) | `scripts/*.sh` | Every release. Follows [SemVer](https://semver.org): major for breaking changes to invocation or output layout, minor for new features, patch for bug fixes. |
| **Config schema version** (`"version": 1` in `backup-config.json`) | `backup-config.json`, enforced at parse time | Only when the config file format changes in a backwards-incompatible way. Currently `1`. |

If you're reporting an issue, include the script ve