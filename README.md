# Claude Code Backup & Restore Guide v2

A config-driven system for backing up and restoring your complete Claude Code environment -- settings, memory, skills, plugins, plans, commands, sessions, and more.

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

## Overview

Claude Code stores a rich set of data across your machine: global instructions, per-project memory, installed skills, plugins, saved plans, custom commands, session transcripts, and MCP server configurations. Losing any of these means rebuilding your environment from scratch.

This guide provides three scripts that back up the full Claude Code data model to a private Git repository:

- **`init.sh`** -- First-time setup. Scans your projects, generates `backup-config.json`.
- **`backup.sh`** -- Config-driven, modular backup with auto-commit and optional auto-push. Fully non-interactive (safe for cron).
- **`restore.sh`** -- Interactive restore with per-category prompts (or `--yes` for unattended restore).

**Requirements:** bash, git, [jq](https://jqlang.github.io/jq/)

## What to Backup

The v2 system backs up every category of Claude Code data that matters for portability:

| Category | Source Location | Backup Directory | Description |
|----------|----------------|------------------|-------------|
| Global instructions | `~/.claude/CLAUDE.md` | `global/` | Custom instructions for all sessions |
| Extra context files | `~/.claude/*.md` | `global/` | Additional markdown context files |
| Settings | `~/.claude/settings.json` | `global/` | Basic settings (e.g., alwaysThinkingEnabled) |
| Local settings | `~/.claude/settings.local.json` | `global/` | Permission rules and advanced settings |
| Keybindings | `~/.claude/keybindings.json` | `global/` | Custom key bindings |
| MCP config | `~/.claude.json` | `global/claude.json` | MCP server definitions, OAuth tokens, app state |
| Skills | `~/.claude/skills/` | `skills/` | User-installed skill packages |
| Plugins | `~/.claude/plugins/` | `plugins/` | Plugin registry (installed_plugins.json, blocklist.json, known_marketplaces.json) |
| Plans | `~/.claude/plans/` | `plans/` | Saved implementation plans |
| Custom commands | `~/.claude/commands/` | `commands/` | User-defined slash commands |
| Todos | `~/.claude/todos/` | `todos/` | Per-session task state |
| Project memory | `~/.claude/projects/<name>/memory/` | `projects/<name>/memory/` | Auto memory files (MEMORY.md, topic files) |
| Session transcripts | `~/.claude/projects/<name>/*.jsonl` | `projects/<name>/sessions/` | Session data for `/resume` support |

## What NOT to Backup

These are excluded because they are sensitive, machine-specific, or regenerated automatically:

| File / Directory | Reason to Exclude |
|------------------|-------------------|
| `.credentials.json` | Authentication tokens (regenerated on login) |
| `history.jsonl` | Chat history -- potentially huge and sensitive |
| `file-history/` | File operation history |
| `debug/` | Debug logs and temporary data |
| `statsig/`, `Cache/` | Analytics and cache data |
| `plugins/cache/`, `plugins/marketplaces/` | Re-downloaded on next launch |
| `projects/*` (non-memory, non-session files) | Runtime state, not portable |

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

# Interactive restore (prompts for each category)
bash /path/to/claude-code-backup-guide/scripts/restore.sh .

# Or non-interactive (restore everything)
bash /path/to/claude-code-backup-guide/scripts/restore.sh . --yes
```

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
    "C--Users-jtkli-projects-Homelab",
    "C--Users-jtkli-projects-my-app"
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

**Project directory names** use Claude Code's encoding scheme where path separators become dashes (e.g., `C--Users-jtkli-projects-Homelab` represents `C:/Users/jtkli/projects/Homelab`). The `init.sh` script handles this mapping for you.

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
│   └── HOMELAB-CONTEXT.md       # any extra *.md files
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
├── todos/
│   └── <session-id>.json
└── projects/
    └── C--Users-jtkli-projects-Homelab/
        ├── memory/
        │   ├── MEMORY.md
        │   └── <topic>.md
        └── sessions/
            ├── <session-id>.jsonl
            └── <session-id>.meta.json
```

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
- Copies all data categories (global settings, MCP config, skills, plugins, plans, commands, todos, project data)
- Only copies files that have changed (uses `cmp` for diffing)
- Removes stale files from the backup that no longer exist in the source
- Stages, commits, and optionally pushes
- Fully non-interactive -- safe for cron or Task Scheduler
- If no backup-directory argument is provided, assumes the script's parent directory is the backup repo
- `--sanitize <output-directory>` produces a credential-free export in the given directory (see [Sanitized Export](#sanitized-export-for-sharing))

#### restore.sh

```
Usage: bash restore.sh [backup-directory] [--yes]
```

- Reads `backup-config.json` from the backup directory
- Prompts interactively for each category (global settings, MCP config, skills, plugins, plans, commands, todos, projects)
- Creates timestamped backups of existing files before overwriting
- `--yes` flag skips all prompts and restores everything
- Session files are restored from `sessions/` subdirectory back to the project root (where Claude Code expects them)
- Prints a verification summary with file counts and sizes

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
- Skills, plans, commands, plugin registry (as-is)
- Per-project memory (interactive selection)

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

### Q: How is v2 different from v1?

**A:** v1 backed up only CLAUDE.md, settings.json, settings.local.json, and a text dump of MCP servers. v2 is a config-driven system that backs up the complete Claude Code data model: memory, skills, plugins, plans, commands, keybindings, the full `~/.claude.json`, session transcripts, and todos. It uses three purpose-built scripts (init, backup, restore) instead of manual copy commands.

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

**A:** The settings files themselves are platform-agnostic. However, project directory names encode the full path (e.g., `C--Users-jtkli-projects-Homelab`), so a backup from Windows will have Windows-style encoded paths. If restoring on macOS/Linux, you may need to update the `projects` list in `backup-config.json` to match the new machine's paths.

### Q: Can I add new projects after initial setup?

**A:** Yes. Either re-run `init.sh` (it will ask before overwriting the config), or manually edit `backup-config.json` and add the project directory name to the `projects` array. Find directory names with `ls ~/.claude/projects/`.

### Q: What happens to existing files during restore?

**A:** The restore script creates timestamped backups of any existing file before overwriting it (e.g., `settings.json.backup.20260305_140000`). You can always roll back by copying the `.backup.*` file over the restored version.

## Additional Resources

- [Backup Script](scripts/backup.sh)
- [Restore Script](scripts/restore.sh)
- [Init Script](scripts/init.sh)
- [.gitignore Template](templates/.gitignore)
- [backup-config.json Template](templates/backup-config.json)

## Contributing

Found an issue or have an improvement? Please:

1. Fork this repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - Feel free to use and modify as needed.
