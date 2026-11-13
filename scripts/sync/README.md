# Keeping machines in sync: the shared-config layer

The backup scripts are disaster recovery: each machine snapshots its own `~/.claude` to
its own repo, and a backup is restored onto the machine it came from. They are not a way
to keep two machines alike. Restoring one machine's backup onto another overwrites the
second machine's own settings.

These scripts are the sync channel. You keep the part of your config that is true on
every machine in a small git repo of its own (the **shared layer**), and each machine
merges it into its `~/.claude`. Everything else stays where it is (the **machine
layer**).

## The split

| What | Shared layer | Machine layer (stays in `~/.claude`) |
|------|--------------|--------------------------------------|
| Instructions | preferences and working style, in `GLOBAL-PREFS.md` | host facts, installed tools, local paths, in the machine's own `CLAUDE.md` |
| `settings.json` | cross-platform permissions and the deny baseline, `autoMode` policy, `modelSettings`, `env`, `enabledPlugins` | `hooks`, `model`, `effortLevel`, `theme`, and any permission naming an OS-specific program or path |
| MCP servers | the server list, in `mcp.shared.json` | each server's tokens, and any extra server |
| Skills, agents, mods | anything portable | anything tied to one machine (reported, never deleted) |
| Memory, scheduled tasks | none | all of it |

## Files

| File | What it does |
|------|--------------|
| `sync-claude-config.sh` | Applies the shared layer. `--check` reports drift and exits 1 (writes nothing); `--dry-run` shows what an apply would change (writes nothing). Exit 2 means it could not run: no `jq`, or the shared folder or one of its three files is missing. |
| `config-check-run.sh` | Scheduled runner: `--check` into a dated log ending in `=== run finished rc=N at <time> ===`, exiting with the check's status. |
| `systemd/claude-config-check.{service,timer}` | Daily check on Linux (systemd user timer). |
| `windows/Check-ClaudeConfig.ps1` | Daily check on Windows, through Git Bash, with optional email. |
| `windows/Register-ClaudeConfigCheck.ps1` | Installs the Windows check as a Scheduled Task. |
| `windows/alert.env.example` | Email settings for the Windows check. Copy to `alert.env` (gitignored). |

## Getting started

1. Create a private repo for your shared layer and start it from the template:

   ```bash
   mkdir ~/claude-shared && cp ~/claude-code-backup-guide/templates/claude-shared/* ~/claude-shared/
   cd ~/claude-shared && git init && git add . && git commit -m "Shared Claude Code config"
   ```

2. Move what is true everywhere into it: preferences from `~/.claude/CLAUDE.md` into
   `GLOBAL-PREFS.md`, cross-platform permissions and plugins into `settings.shared.json`,
   MCP server definitions (without tokens) into `mcp.shared.json`. Add `skills/`,
   `agents/`, or `mods/` folders, and a `statusline-command.sh`, if you share those.
3. Preview, then apply, on each machine:

   ```bash
   bash ~/claude-code-backup-guide/scripts/sync/sync-claude-config.sh --dry-run ~/claude-shared
   bash ~/claude-code-backup-guide/scripts/sync/sync-claude-config.sh ~/claude-shared
   ```

   Or set `CLAUDE_SHARED_DIR=~/claude-shared` once and leave the folder off.

## What an apply changes, and nothing else

| Shared file | Goes to | How |
|-------------|---------|-----|
| `GLOBAL-PREFS.md` | `~/.claude/CLAUDE.md` | One `@`-import line, appended once. The machine's own text is untouched. |
| `settings.shared.json` | `~/.claude/settings.json` | Permission and `autoMode` lists are joined; `env`, `modelSettings`, `enabledPlugins` are merged key by key with the shared value winning; other top-level shared values are set. `statusLine` is set only if the machine has none. Anything listed in `retiredAllows` is removed from `permissions.allow`. |
| `mcp.shared.json` | `~/.claude.json` `mcpServers` | Shared servers are added or updated; each server keeps this machine's `env` values, where tokens live. On Windows an `npx` command is wrapped in `cmd /c`. Nothing from this file is printed. |
| `skills/`, `agents/`, `mods/` | the same folders in `~/.claude` | One-way copy, shared layer wins. An entry only the machine has is reported as `untracked`, never deleted. `skills/synced`, where Claude Code keeps its own copy of the account's skills, is left out of that list. |
| `mods/<name>/` | `env.CLAUDE_CODE_PLUGIN_DIRS` | Set to the list of mods, `:`-separated (`;` on Windows). |
| `enabledPlugins` | `claude plugin install` | Each enabled plugin is installed if missing. |
| `statusline-command.sh` | `~/.claude/statusline-command.sh` | One-way copy. |

The previous `settings.json` and `~/.claude.json` are saved as `.bak` before an apply
changes them.

**The merge is additive.** Re-running it is always safe, and local extras are kept. The
cost is that **deletions do not travel**: removing an entry from `settings.shared.json`
does not remove it from a machine that already has it. To retire a permission everywhere,
move it to `retiredAllows`. Anything else is removed by hand on each machine.

**Author in the shared repo.** A shared skill edited directly in `~/.claude/skills/` is
overwritten by the next apply. To share a machine's `untracked` skill, move it into the
shared repo.

## Daily drift check

Both checks only report. Neither fixes drift: a machine silently rewriting its own config
hides the differences you wanted to see. Both fetch the shared repo first and note when
the local copy is behind, since a stale checkout would report "in sync" against an old
shared layer.

**Linux (systemd):** edit the two paths in `systemd/claude-config-check.service`, then:

```bash
cp ~/claude-code-backup-guide/scripts/sync/systemd/claude-config-check.* ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now claude-config-check.timer
```

Drift marks the unit failed (`systemctl --user status claude-config-check.service`). Logs
go to `~/.local/state/claude-config-check/` (or `$CLAUDE_CHECK_LOG_DIR`).

**Windows (Task Scheduler):**

```powershell
.\scripts\sync\windows\Register-ClaudeConfigCheck.ps1 -SharedDir C:\Users\me\claude-shared
```

Drift shows as `1` in Task Scheduler's "Last Run Result" and in the log under
`%LOCALAPPDATA%\claude-config-check\`. Copy `alert.env.example` to `alert.env` for an
email as well.

## Notes for editing the PowerShell

These broke the Windows check once, and none of them shows up on Linux:

- **Save `.ps1` files as UTF-8 with a BOM.** Without it, Windows PowerShell 5.1 reads the
  file as Windows-1252, an em dash becomes a curly quote, and the script does not parse.
- **Never pair `2>&1` on a native command with `$ErrorActionPreference = 'Stop'`.** It
  throws before the exit code is read. The sync script reports drift on stderr, so this
  fails only when there is drift: an empty log, no email, a misleading result.
- **Set the output encoding.** Task Scheduler's console uses the OEM codepage, so UTF-8
  output logs as `ΓÇö` unless `[Console]::OutputEncoding` is set to UTF-8.
- **Git Bash paths.** `pwd` gives `/c/Users/...`, which Claude Code on Windows cannot
  resolve in an `@`-import. The sync script uses `pwd -W` so the import line reads
  `C:/Users/...`.

Treat a PowerShell change as unverified until it has run on Windows.
