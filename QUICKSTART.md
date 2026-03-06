# Quick Start Guide (v2)

Back up your Claude Code settings in 5 minutes.

## Prerequisites

- Claude Code installed (run it at least once so `~/.claude/` exists)
- Git, bash, and **jq** installed
- A GitHub account (or other Git hosting)

## Backup Setup

```bash
# 1. Create a private GitHub repo for your backup
gh repo create claude-code-backup --private --clone
cd claude-code-backup

# 2. Get the scripts (clone guide repo or copy scripts/ directory)
git clone https://github.com/jtklinger/claude-code-backup-guide.git /tmp/cbg
cp /tmp/cbg/scripts/*.sh ./scripts/
cp /tmp/cbg/templates/.gitignore .

# 3. Run init — scans projects, generates backup-config.json
bash scripts/init.sh .

# 4. Run first backup
bash scripts/backup.sh .

# 5. Push to GitHub
git push -u origin main
```

Done. Your settings, MCP config, skills, plans, commands, session transcripts, todos, and per-project memory are all backed up.

## What Gets Backed Up

| Category | Source | Details |
|---|---|---|
| Global settings | `~/.claude/` | CLAUDE.md, settings.json, keybindings.json, extra *.md files |
| MCP config | `~/.claude.json` | Full file (server definitions, OAuth tokens) |
| Skills | `~/.claude/skills/` | All skill files |
| Plugins | `~/.claude/plugins/` | Registry files (not cache) |
| Plans | `~/.claude/plans/` | Saved plan documents |
| Commands | `~/.claude/commands/` | Custom slash commands |
| Todos | `~/.claude/todos/` | Per-session task state |
| Projects | `~/.claude/projects/` | MEMORY.md, topic files, session transcripts |

## Restore on New Machine

```bash
# 1. Clone your backup repo
git clone https://github.com/YOUR_USERNAME/claude-code-backup.git
cd claude-code-backup

# 2. Install jq if not already present
#    macOS: brew install jq
#    Linux: sudo apt install jq
#    Windows: winget install jqlang.jq

# 3. Run restore (interactive — prompts per category)
bash scripts/restore.sh .

# 4. Restart Claude Code
```

Use `--yes` to skip prompts and restore everything: `bash scripts/restore.sh . --yes`

## Automate Backups

**Linux/macOS (cron):**

```
0 2 * * * /path/to/scripts/backup.sh /path/to/claude-code-backup
```

**Windows (Task Scheduler):**

- Program: `C:\Program Files\Git\bin\bash.exe`
- Arguments: `/path/to/scripts/backup.sh /path/to/claude-code-backup`

To auto-push after each backup, set `"git_auto_push": true` in `backup-config.json`.

## Troubleshooting

**"jq not found"** — Install jq before running backup or restore.

**"Config file not found"** — Run `init.sh` first to generate `backup-config.json`.

**Script won't run** — `chmod +x scripts/*.sh` then retry.

## Next Steps

- [Full documentation](README.md) for detailed explanations
- [Report an issue](https://github.com/jtklinger/claude-code-backup-guide/issues)

---

**Keep your backup repository private** — it contains infrastructure details and MCP server configurations.
