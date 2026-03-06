# Claude Code Backup v2 — Design Document

**Date**: 2026-03-05
**Status**: Approved

## Problem

The original backup guide (v1) only covers `CLAUDE.md`, `settings.json`, `settings.local.json`, and a text dump of `claude mcp list`. Since then, Claude Code has added:

- **Auto memory** — per-project persistent memory (`projects/*/memory/`)
- **Skills** — user-installed skill packages (`skills/`)
- **Plugins** — plugin registry and installed state (`plugins/`)
- **Plans** — saved implementation plans (`plans/`)
- **Custom commands** — user slash commands (`commands/`)
- **Keybindings** — custom keyboard shortcuts (`keybindings.json`)
- **Extra context files** — additional `*.md` files in `~/.claude/` (e.g., `PROJECT-CONTEXT.md`)
- **MCP config in `~/.claude.json`** — the actual MCP server definitions, not just a text list
- **Todos** — per-session task state (`todos/`)
- **Session transcripts** — full conversation history per project (`projects/*/*.jsonl`)

The v1 scripts don't back up any of these. A laptop failure would lose all learned context, skills, and session history.

## Goals

1. Comprehensive backup of all Claude Code data needed for full recovery on a new machine
2. Config-driven — explicit project list, toggleable features
3. Non-interactive mode for scheduled execution (cron / Task Scheduler)
4. Git-based with auto-commit and optional auto-push to GitHub
5. Cross-platform (Windows Git Bash, macOS, Linux)

## Non-Goals (Future)

- GUI front-end for config/scheduling (planned future phase)
- S3/Backblaze storage target (planned future phase)
- Incremental/differential backups (file-level copy with change detection is sufficient)

## Data Model

### What Gets Backed Up

| Category | Source | Destination in Repo | Notes |
|----------|--------|-------------------|-------|
| Global settings | `~/.claude/CLAUDE.md` | `global/CLAUDE.md` | |
| Global settings | `~/.claude/settings.json` | `global/settings.json` | |
| Global settings | `~/.claude/settings.local.json` | `global/settings.local.json` | |
| Global settings | `~/.claude/keybindings.json` | `global/keybindings.json` | If exists |
| Global settings | `~/.claude/*.md` (extra context) | `global/*.md` | e.g., PROJECT-CONTEXT.md |
| MCP + app state | `~/.claude.json` | `global/claude.json` | Full file including MCP servers |
| Skills | `~/.claude/skills/` | `skills/` | Full recursive copy |
| Plugins | `~/.claude/plugins/installed_plugins.json` | `plugins/installed_plugins.json` | |
| Plugins | `~/.claude/plugins/blocklist.json` | `plugins/blocklist.json` | |
| Plugins | `~/.claude/plugins/known_marketplaces.json` | `plugins/known_marketplaces.json` | |
| Plans | `~/.claude/plans/*.md` | `plans/` | |
| Commands | `~/.claude/commands/*.md` | `commands/` | If any exist |
| Todos | `~/.claude/todos/*.json` | `todos/` | Supports session resume |
| Project memory | `projects/<name>/memory/` | `projects/<name>/memory/` | Per configured project |
| Project sessions | `projects/<name>/*.jsonl` | `projects/<name>/sessions/` | Toggleable, default on |

### What Is Excluded

| Item | Reason |
|------|--------|
| `.credentials.json` | OAuth tokens, regenerated on login |
| `history.jsonl` | Global history, huge, duplicated by session transcripts |
| `cache/`, `debug/`, `statsig/`, `telemetry/` | Ephemeral runtime data |
| `paste-cache/`, `shell-snapshots/`, `session-env/` | Transient session data |
| `file-history/`, `ide/`, `backups/` | Machine-specific state |
| `tasks/` | Runtime lock/coordination files |
| `plugins/cache/` | Downloaded plugin content, re-fetched on install |
| `stats-cache.json` | Regenerated |

## Config File

`backup-config.json` in the backup repo root:

```json
{
  "version": 1,
  "claude_dir": "~/.claude",
  "include_sessions": true,
  "include_todos": true,
  "projects": [
    "C--Users-me-projects-myproject",
    "C--Users-me-projects-claude-code-backup-guide",
    "C--Users-me-projects"
  ],
  "git_auto_push": true,
  "git_remote": "origin",
  "git_branch": "main"
}
```

- `projects` lists the hashed folder names under `~/.claude/projects/`
- Script warns if a configured project directory is missing
- All `~` paths expand at runtime

## Script Architecture

### backup.sh

Modular functions, one per data category:

1. `backup_global_settings()` — CLAUDE.md, settings, keybindings, extra *.md files
2. `backup_mcp_config()` — ~/.claude.json → global/claude.json
3. `backup_skills()` — recursive copy of skills/
4. `backup_plugins()` — copy plugin registry files (not cache)
5. `backup_plans()` — copy plans/*.md
6. `backup_commands()` — copy commands/*.md
7. `backup_todos()` — copy todos/*.json
8. `backup_projects()` — iterate configured projects, copy memory/ and optionally sessions

Change detection via `cmp` or `diff` to avoid unnecessary git commits.

Flow:
1. Read and validate `backup-config.json`
2. Expand `~` paths for the platform
3. Run each backup function
4. Security check (informational warning for known sensitive patterns)
5. If changes: `git add`, `git commit` with timestamp
6. If `git_auto_push`: push to configured remote/branch

### restore.sh

Reverse of backup with interactive confirmation:

1. Read `backup-config.json`
2. For each category, prompt before overwriting existing files
3. Back up existing files with `.backup.<timestamp>` suffix before overwriting
4. Restore in order: global settings → claude.json → skills → plugins → plans → commands → todos → project data
5. Print verification summary

### init.sh (new)

First-time setup helper:
1. Initialize git repo in backup directory
2. Scan `~/.claude/projects/` and present available projects for selection
3. Generate `backup-config.json`
4. Run first backup

## Backup Repo Layout

```
backup-repo/
├── backup-config.json
├── .gitignore
├── scripts/
│   ├── backup.sh
│   ├── restore.sh
│   └── init.sh
├── global/
│   ├── CLAUDE.md
│   ├── PROJECT-CONTEXT.md
│   ├── settings.json
│   ├── settings.local.json
│   ├── keybindings.json
│   └── claude.json
├── skills/
│   └── <skill-name>/
├── plugins/
│   ├── installed_plugins.json
│   ├── blocklist.json
│   └── known_marketplaces.json
├── plans/
│   └── *.md
├── commands/
│   └── *.md
├── todos/
│   └── *.json
└── projects/
    └── <project-hash-name>/
        ├── memory/
        │   ├── MEMORY.md
        │   └── *.md
        └── sessions/
            └── *.jsonl
```

## Scheduling

### Linux/macOS (cron)
```
0 2 * * * /path/to/backup-repo/scripts/backup.sh /path/to/backup-repo
```

### Windows (Task Scheduler)
```
Program: C:\Program Files\Git\bin\bash.exe
Arguments: C:\path\to\backup-repo\scripts\backup.sh C:\path\to\backup-repo
```

## Security Considerations

- `~/.claude.json` contains OAuth tokens — backup repo MUST be private
- `settings.local.json` may contain permission patterns revealing infrastructure
- MCP server configs may contain passwords in command args
- The script prints an informational security summary but does NOT block commits (user chose full backup as-is)

## Future Phases

1. **GUI front-end** — Cross-platform app to configure projects, schedule backups, view history
2. **S3/Backblaze target** — Copy backup to object storage after git commit
3. **Selective restore** — Choose which categories to restore individually
