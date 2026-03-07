# Sanitized Export Feature Design

**Date:** 2026-03-07
**Issue:** #2 — Add ability to sanitize and export for sharing

## Overview

Add a `--sanitize <output-dir>` flag to `backup.sh` that produces a credential-free, shareable copy of Claude Code settings. Supports both public template sharing and team onboarding use cases.

## CLI Interface

```
bash backup.sh [backup-directory] --sanitize <output-directory>
```

- Runs the normal backup first, then copies the result to the output directory with sanitization applied
- Output directory is created if it doesn't exist; contents are overwritten if it does (clean snapshot)
- No git operations on the output directory
- Normal backup without `--sanitize` is completely unchanged

## Sanitization Rules

### global/claude.json

Derived from `~/.claude.json`. Only `mcpServers` is kept; everything else is stripped.

| Key | Action |
|-----|--------|
| `mcpServers` | Keep structure, redact sensitive values (see heuristics below) |
| `oauthAccount` | Remove (email, org, UUIDs) |
| `userID`, `anonymousId` | Remove |
| `projects`, `githubRepoPaths` | Remove (local paths) |
| All other keys | Remove (app state, not useful to share) |

**MCP server arg redaction heuristics:**

- Args with `--host=*` → `--host=<HOSTNAME>`
- Args with `--user=*` → `--user=<USERNAME>`
- Args with `--key=*` → `--key=<SSH_KEY_PATH>`
- Args matching hostname patterns (`*.com`, `*.local`, IPs) → `<HOSTNAME>`
- Args containing file paths (`/home/`, `C:/`, `~/`) → `<PATH>`
- `env` object: all values replaced with `<REDACTED>`
- Package names (contain `@` or `-y` flag targets) and structural flags (`--`, `/c`) → kept as-is
- `command` field → kept as-is (e.g., `cmd`, `npx`)
- `type` field → kept as-is

### global/settings.json and settings.local.json

- `permissions.allow`: Keep non-MCP entries as-is. For `mcp__*` entries, replace server name with `<server>` (e.g., `mcp__ssh-mcp-kvm01__exec` → `mcp__<server>__exec`). Deduplicate resulting patterns.
- All other fields (`enabledPlugins`, `alwaysThinkingEnabled`, `defaultMode`): kept as-is

### Files copied without sanitization

- `CLAUDE.md` and extra `*.md` context files
- `keybindings.json`
- `skills/` (all files)
- `plugins/` (registry files only)
- `plans/` (all `.md` files)
- `commands/` (all `.md` files)

### Excluded from export entirely

- Sessions (`.jsonl`, `.meta.json`) — large, conversation-specific
- Todos — session-specific task state

### Per-project memory

Interactive prompt per project: "Include memory for project X? [Y/n]". Always interactive — no `--yes` equivalent for export (sharing should be deliberate).

## Implementation Structure

Single new function `sanitize_and_export()` added to `backup.sh`, called after the normal backup completes:

```
sanitize_and_export()
├── sanitize_claude_json()    # jq transforms on global/claude.json
├── sanitize_settings()       # redact mcp__ permissions in settings files
├── copy_safe_files()         # CLAUDE.md, keybindings, skills, plugins, plans, commands
└── prompt_project_memory()   # interactive per-project selection
```

- All JSON sanitization done with `jq` (no sed/regex on JSON)
- Output directory gets an auto-generated `README.md` describing what was exported, what was redacted, and that MCP placeholders need to be filled in
- No `backup-config.json` or `.gitignore` in the export — it's not a backup repo

## Config changes

None. `--sanitize` is purely a CLI flag.

## Documentation

Add a "Sanitized Export" section to README.md covering:
- Usage and examples
- What gets redacted
- How to fill in MCP placeholders after receiving an export
