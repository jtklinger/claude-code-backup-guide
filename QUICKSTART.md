# Quick Start Guide

Get your Claude Code settings backed up in 5 minutes!

## Prerequisites

- Claude Code installed
- Git installed
- GitHub account (or other Git hosting)

## For the Impatient

```bash
# 1. Create backup directory
mkdir ~/claude-code-settings-backup
cd ~/claude-code-settings-backup

# 2. Download and run backup script
curl -O https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/backup.sh
bash backup.sh

# 3. Create GitHub repo (or use gh CLI)
gh repo create claude-code-settings-backup --private

# 4. Push to GitHub
git remote add origin https://github.com/YOUR_USERNAME/claude-code-settings-backup.git
git add .
git commit -m "Initial Claude Code backup"
git push -u origin main
```

Done! Your settings are backed up.

## Restore on New Machine

```bash
# 1. Clone your backup
git clone https://github.com/YOUR_USERNAME/claude-code-settings-backup.git
cd claude-code-settings-backup

# 2. Run restore script
curl -O https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/restore.sh
bash restore.sh

# 3. Restart Claude Code
```

## What Gets Backed Up?

- ✅ Global instructions (CLAUDE.md)
- ✅ Basic settings (settings.json)
- ✅ Permissions (sanitized, no passwords)
- ✅ MCP server list (for reference)

## What Doesn't Get Backed Up?

- ❌ Credentials (.credentials.json)
- ❌ Chat history
- ❌ Debug logs
- ❌ Temporary files

## Next Steps

- [Read the full guide](README.md) for detailed instructions
- [Set up automatic backups](README.md#faq) with cron
- [Configure MCP servers](README.md#restoring-on-a-new-machine)

## Troubleshooting

### Script won't run

```bash
# Make it executable
chmod +x backup.sh
./backup.sh
```

### Can't find settings

```bash
# Check if Claude Code is installed
ls ~/.claude/

# If empty, install Claude Code first
```

### Found real passwords in backup

```bash
# The backup script should catch this
# If you see this error, review files before committing:
grep -i "password" ./*

# Never commit real passwords!
```

## Platform-Specific Notes

### Windows (Git Bash)

```bash
# Use Git Bash or WSL
# Paths like ~/.claude work in Git Bash
# Full path: C:\Users\<username>\.claude
```

### macOS

```bash
# Everything should work as shown
```

### Linux

```bash
# Everything should work as shown
```

## Need Help?

- [Full documentation](README.md)
- [Report an issue](https://github.com/jtklinger/claude-code-backup-guide/issues)
- [Contributing guide](CONTRIBUTING.md)

---

**Remember**: Always keep your backup repository **private** to protect your infrastructure details!
