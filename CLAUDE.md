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

## Key Conventions

- All scripts use `set -e` and colored output (`GREEN`/`YELLOW`/`RED`/`NC`)
- Config is `backup-config.json` in backup repo root — parsed with `jq`
- Change detection via `cmp -s` to avoid unnecessary git commits
- Skills sync prefers `rsync --delete` with fallback to manual `find`/`cp`
- Session .jsonl files are stored in `projects/<name>/sessions/` in the backup but restored to `projects/<name>/` (the project root) where Claude Code reads them
- Cross-platform: Windows Git Bash, macOS, Linux — paths use `$HOME/.claude`
- `~/.claude.json` (in HOME, outside `.claude/`) holds MCP server configs and is backed up as `global/claude.json`
- `--sanitize <output-dir>` flag on backup.sh produces a credential-free export for sharing (strips OAuth, MCP credentials, app state; redacts hostnames/paths in server configs)

## Data Categories

The backup covers: global settings (incl. custom root scripts like `*.cmd`/`*.ps1`/`*.sh`), MCP config, skills, plugins (registry + plugin data under `plugins/data/`), user-content directories (plans, commands, agents, output-styles, rules, hooks, scheduled-tasks), todos, per-project memory, session transcripts, subagent transcripts, and session tool-result payloads. See `docs/plans/2026-03-05-backup-v2-design.md` for the full data model.

User-content directories are driven by a shared `USER_CONTENT_DIRS` array in `backup.sh` and `restore.sh` (format `"name:glob"`) — adding a new category is one edit per script. Subagent transcripts and tool-results live under `projects/<hash>/<session-uuid>/{subagents,tool-results}/` on disk and are stored in the backup at `projects/<hash>/{subagents,tool-results}/<session-uuid>/`.

## Testing Changes

No test suite. To validate:

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
