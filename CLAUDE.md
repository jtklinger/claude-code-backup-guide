# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Config-driven toolkit for backing up and restoring the full Claude Code environment (`~/.claude/`, `~/.claude.json`) across machines. Bash scripts + Markdown docs — not a software application. Requires `jq` and `git`.

## Repository Structure

- `scripts/init.sh` — First-time setup: scans `~/.claude/projects/`, generates `backup-config.json`
- `scripts/backup.sh` — Non-interactive backup (cron-safe): reads config, copies changed files, auto-commits, optionally pushes
- `scripts/restore.sh` — Interactive restore with per-category prompts (`--yes` for unattended; `--dry-run` to preview NEW/CHANGED/SAME classification without writing anything)
- `templates/.gitignore` — Recommended `.gitignore` for user backup repositories
- `templates/backup-config.json` — Default config template
- `docs/plans/` — Design documents
- `scripts/windows/` — **Optional Windows-only observability layer** (PowerShell): wraps the scheduled backup to log each run to a file + the Windows Event Log and toast on success/failure, plus a watchdog for missed runs. Does not modify the portable `backup.sh`. Install with `-Fast` (bake in `--fast`) and/or `-Silent` (hidden window, no console pop-up). See `scripts/windows/README.md`.
- `.github/workflows/lint.yml` — **CI lint guard**: `bash -n` on every script (hard gate) + ShellCheck/PSScriptAnalyzer (advisory) on push/PR. Stops a syntax-broken script (the v2.2.0 failure mode) from reaching `master`.

## Key Conventions

- All scripts use `set -e` and colored output (`GREEN`/`YELLOW`/`RED`/`NC`)
- Config is `backup-config.json` in backup repo root — parsed with `jq`
- `projects` in the config is pattern-based (bash globs), resolved dynamically against `~/.claude/projects/` at backup time — not a fixed list. `["*"]` (default) discovers everything including git worktree sessions, whose slugs are randomly generated per-worktree and can't be enumerated in advance. Exact slugs and prefix globs still work for scoping down; `[]` opts out of project/session backup entirely.
- Change detection via `cmp -s` (byte-exact) by default to avoid unnecessary git commits; `backup.sh --fast` switches to size + mtime (one `stat` per file, skips reading every byte) — opt-in, default stays byte-exact
- Skills sync prefers `rsync --delete` with fallback to manual `find`/`cp`
- Session .jsonl files are stored in `projects/<name>/sessions/` in the backup but restored to `projects/<name>/` (the project root) where Claude Code reads them
- Cross-platform: Windows Git Bash, macOS, Linux — paths use `$HOME/.claude`
- `~/.claude.json` (in HOME, outside `.claude/`) holds MCP server configs and is backed up as `global/claude.json`
- `--sanitize <output-dir>` flag on backup.sh produces a credential-free export for sharing (strips OAuth, MCP credentials, app state; redacts hostnames/paths in server configs)

## Data Categories

The backup covers: global settings (incl. custom root scripts like `*.cmd`/`*.ps1`/`*.sh`), MCP config, skills, plugins (registry + plugin data under `plugins/data/`), user-content directories (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks), todos, per-project memory, session transcripts, subagent transcripts, and session tool-result payloads. See `docs/plans/2026-03-05-backup-v2-design.md` for the full data model.

User-content directories are driven by a shared `USER_CONTENT_DIRS` array in `backup.sh` and `restore.sh` (format `"name:glob"`) — adding a new category is one edit per script. Subagent transcripts and tool-results live under `projects/<hash>/<session-uuid>/{subagents,tool-results}/` on disk and are stored in the backup at `projects/<hash>/{subagents,tool-results}/<session-uuid>/`.

## Testing Changes

No unit test suite (CI runs `bash -n` + linters via `.github/workflows/lint.yml`). To validate behavior locally:

```bash
# First-time setup (creates config + .gitignore)
mkdir /tmp/test-backup && bash scripts/init.sh /tmp/test-backup

# Run backup
bash scripts/backup.sh /tmp/test-backup

# Verify idempotency (should report "no changes")
bash scripts/backup.sh /tmp/test-backup

# Test restore
bash scripts/restore.sh /tmp/test-backup --yes

# Cleanup
rm -rf /tmp/test-backup
```
