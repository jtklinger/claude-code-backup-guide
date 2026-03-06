# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a documentation and shell-script toolkit for backing up and restoring Claude Code settings (`~/.claude/`) across machines. It is not a software application — it consists of Markdown guides and Bash scripts.

## Repository Structure

- `scripts/backup.sh` — Interactive backup script; copies settings to a git-backed directory and sanitizes credentials via `sed`
- `scripts/restore.sh` — Interactive restore script; copies settings back to `~/.claude/` with pre-existing file backup
- `scripts/auto-backup.sh` — Non-interactive backup for cron/Task Scheduler; only commits when files actually changed; includes auto-push
- `scripts/restore-mcp-template.sh` — Template for restoring MCP servers via `claude mcp add`; must be customized before use
- `templates/.gitignore` — Recommended `.gitignore` for user backup repositories
- `README.md` — Full guide (backup/restore procedures, security practices, troubleshooting)
- `QUICKSTART.md` — Condensed 5-minute setup guide

## Key Conventions

- All scripts use `set -e` and colored output (`GREEN`/`YELLOW`/`RED`/`NC` variables)
- Credential sanitization replaces `password=`, `apiKey=`, `token=`, `secret=`, `key=` values with `YOUR_*_HERE` placeholders
- `settings.local.json` is always saved as `.template` (never the raw file) to prevent credential leaks
- Scripts are designed to work on Windows (Git Bash/WSL), macOS, and Linux — paths use `$HOME/.claude`

## Testing Changes

There is no test suite. To validate changes:

```bash
# Test backup script (creates files in a temp directory)
bash scripts/backup.sh /tmp/test-backup

# Test restore script (reads from a directory)
bash scripts/restore.sh /tmp/test-backup
```

Verify scripts handle missing files gracefully (e.g., no `CLAUDE.md`, no `settings.json`) and that the security check at the end of `backup.sh` / `auto-backup.sh` catches unsanitized credentials.
