# Claude Code Settings Backup & Restore Guide

A comprehensive guide to backing up and restoring your Claude Code settings across machines.

## Table of Contents

- [Overview](#overview)
- [What to Backup](#what-to-backup)
- [What NOT to Backup](#what-not-to-backup)
- [Platform-Specific Locations](#platform-specific-locations)
- [Quick Start](#quick-start)
- [Detailed Instructions](#detailed-instructions)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

## Overview

Claude Code stores settings in several locations on your machine. This guide helps you:

- **Backup** your settings to a private Git repository
- **Restore** settings on a new machine
- **Maintain security** by handling credentials properly
- **Share configurations** across your devices

## What to Backup

These files contain your preferences and should be backed up:

| File | Description | Platform |
|------|-------------|----------|
| `CLAUDE.md` | Global instructions for Claude | All |
| `settings.json` | Basic settings (e.g., alwaysThinkingEnabled) | All |
| `settings.local.json` | Permissions and advanced settings | All |
| MCP server configs | Model Context Protocol server configurations | All |
| Project-specific `CLAUDE.md` | Per-project instructions | All |

### Important Settings Files

**Global Instructions** (`CLAUDE.md`)
- Custom instructions that apply to all Claude Code sessions
- Personal coding preferences, style guides, etc.
- Located in: `~/.claude/CLAUDE.md`

**Basic Settings** (`settings.json`)
- Simple key-value settings
- Example: `{"alwaysThinkingEnabled": true}`
- Located in: `~/.claude/settings.json`

**Advanced Settings** (`settings.local.json`)
- Permission rules (which commands/tools are auto-approved)
- May contain sensitive data (passwords, API keys)
- **Requires sanitization** before backup
- Located in: `~/.claude/settings.local.json`

**MCP Server Configurations**
- SSH connections, database connections, custom tools
- Stored in Claude Code's configuration system
- Export with: `claude mcp list`

## What NOT to Backup

These files contain sensitive or machine-specific data:

| File/Directory | Reason to Exclude |
|----------------|-------------------|
| `.credentials.json` | Authentication tokens (regenerated on login) |
| `history.jsonl` | Chat history (potentially sensitive, very large) |
| `todos/` | Temporary task tracking data |
| `file-history/` | File operation history |
| `debug/` | Debug logs and temporary data |
| `projects/` | Project-specific runtime state |
| `statsig/`, `Cache/` | Analytics and cache data |

## Platform-Specific Locations

### Windows

```
C:\Users\<username>\.claude\
```

Access in Git Bash or WSL:
```bash
~/.claude/
```

### macOS

```
/Users/<username>/.claude/
```

Or:
```bash
~/.claude/
```

### Linux

```
/home/<username>/.claude/
```

Or:
```bash
~/.claude/
```

## Quick Start

### 1. Create a Private Backup Repository

```bash
# Create a new private GitHub repo
gh repo create claude-code-settings-backup --private

# Create local directory
mkdir ~/claude-code-settings-backup
cd ~/claude-code-settings-backup
git init

# Add .gitignore
curl -o .gitignore https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/templates/.gitignore
```

### 2. Run the Backup Script

Download and run the platform-appropriate backup script:

**Windows (Git Bash/WSL)**:
```bash
curl -o backup.sh https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/backup.sh
bash backup.sh
```

**macOS/Linux**:
```bash
curl -o backup.sh https://raw.githubusercontent.com/jtklinger/claude-code-backup-guide/main/scripts/backup.sh
chmod +x backup.sh
./backup.sh
```

### 3. Commit and Push

```bash
git add .
git commit -m "Initial Claude Code settings backup"
git remote add origin https://github.com/YOUR_USERNAME/claude-code-settings-backup.git
git push -u origin main
```

### 4. Restore on New Machine

```bash
# Clone your backup
git clone https://github.com/YOUR_USERNAME/claude-code-settings-backup.git
cd claude-code-settings-backup

# Run restore script
bash restore.sh
```

## Detailed Instructions

### Creating a Backup

#### Step 1: Create Directory Structure

```bash
mkdir ~/claude-code-settings-backup
cd ~/claude-code-settings-backup
git init
```

#### Step 2: Create .gitignore

Create a `.gitignore` file to prevent committing sensitive data:

```gitignore
# Never commit actual credentials
.credentials.json
*credentials*
*.key
*.pem

# Temporary files
*.tmp
*.bak
*~

# OS files
.DS_Store
Thumbs.db
desktop.ini

# Editor files
.vscode/
.idea/
*.swp
```

#### Step 3: Copy Safe Configuration Files

```bash
# Copy global instructions
cp ~/.claude/CLAUDE.md .

# Copy basic settings
cp ~/.claude/settings.json .
```

#### Step 4: Sanitize settings.local.json

**⚠️ CRITICAL**: Never commit passwords or API keys!

Create a sanitized version:

```bash
# Remove passwords and sensitive data
cat ~/.claude/settings.local.json | \
  sed 's/password="[^"]*"/password="YOUR_PASSWORD_HERE"/g' | \
  sed "s/password=''[^'']*''/password=''YOUR_PASSWORD_HERE''/g" | \
  sed 's/apiKey="[^"]*"/apiKey="YOUR_API_KEY"/g' | \
  sed 's/token="[^"]*"/token="YOUR_TOKEN"/g' > \
  settings.local.json.template
```

#### Step 5: Export MCP Server List

```bash
# Export current MCP servers (for reference)
claude mcp list > mcp-servers.txt 2>&1
```

#### Step 6: Create MCP Restore Script

See [scripts/restore-mcp-template.sh](scripts/restore-mcp-template.sh) for a template.

#### Step 7: Commit to Git

```bash
git add .
git commit -m "Backup Claude Code settings"
git remote add origin YOUR_REPO_URL
git push -u origin main
```

### Restoring on a New Machine

#### Step 1: Install Claude Code

Follow the official installation instructions at https://claude.com/claude-code

#### Step 2: Clone Your Backup

```bash
git clone YOUR_BACKUP_REPO_URL
cd claude-code-settings-backup
```

#### Step 3: Restore Basic Settings

```bash
# Copy global instructions
cp CLAUDE.md ~/.claude/

# Copy basic settings
cp settings.json ~/.claude/
```

#### Step 4: Restore Permissions (Optional)

**Option A: Let Claude Code regenerate (Recommended)**
- Simply use Claude Code and approve commands as needed
- Claude Code will build up `settings.local.json` automatically
- Safest approach

**Option B: Restore manually**
1. Edit `settings.local.json.template`
2. Replace placeholders with actual credentials
3. Rename to `settings.local.json`
4. Copy to `~/.claude/`

```bash
# After editing with real credentials
cp settings.local.json ~/.claude/
```

#### Step 5: Restore MCP Servers

Review `mcp-servers.txt` for your server list, then:

**Option A: Use the restore script**
```bash
# Edit restore-mcp-servers.sh to add credentials
nano restore-mcp-servers.sh

# Run the script
bash restore-mcp-servers.sh
```

**Option B: Add manually**
```bash
# Example: Add an SSH MCP server
claude mcp add -s user --transport stdio my-server -- \
  npx -y ssh-mcp \
  --host=server.example.com \
  --user=myuser \
  --password="mypassword"
```

#### Step 6: Verify

```bash
# Check settings
cat ~/.claude/CLAUDE.md
cat ~/.claude/settings.json

# Check MCP servers
claude mcp list
```

## Security Best Practices

### 1. Use a Private Repository

Your settings may contain:
- Infrastructure details (server names, IPs)
- Permission patterns that reveal your setup
- File paths and directory structures

**Always use a private repository** unless you're sharing only generic templates.

### 2. Never Commit Credentials

Use placeholders in committed files:
- `YOUR_PASSWORD_HERE` for passwords
- `YOUR_API_KEY` for API keys
- `YOUR_TOKEN` for authentication tokens

### 3. Sanitize Before Committing

Always review files before committing:

```bash
# Check for passwords
grep -i "password" ./* 2>/dev/null

# Check for API keys
grep -i "api" ./* 2>/dev/null

# Check for tokens
grep -i "token" ./* 2>/dev/null
```

### 4. Use SSH Keys Instead of Passwords

Where possible, configure SSH key-based authentication instead of passwords:

```bash
# Generate SSH key
ssh-keygen -t ed25519 -C "claude-code@yourdomain.com"

# Use with MCP server
claude mcp add -s user --transport stdio my-server -- \
  npx -y ssh-mcp \
  --host=server.example.com \
  --user=myuser \
  --identity=/path/to/private/key
```

### 5. Rotate Credentials if Exposed

If you accidentally commit credentials:

1. **Immediately change the credentials** on the affected systems
2. Remove from Git history:
   ```bash
   # Remove file from Git history
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch FILENAME" \
     --prune-empty --tag-name-filter cat -- --all

   # Force push
   git push origin --force --all
   ```
3. Consider the credentials compromised and rotate them

### 6. Use Environment Variables

For sensitive values, consider using environment variables:

```bash
# Set environment variable
export MY_SERVER_PASSWORD="secret"

# Use in MCP server config
claude mcp add -s user --transport stdio my-server -- \
  npx -y ssh-mcp \
  --host=server.example.com \
  --user=myuser \
  --password="$MY_SERVER_PASSWORD"
```

## Troubleshooting

### Settings Not Applying

**Problem**: Settings don't seem to take effect after restore

**Solution**:
1. Restart Claude Code completely
2. Check file permissions: `ls -la ~/.claude/`
3. Verify file contents: `cat ~/.claude/settings.json`

### MCP Servers Not Connecting

**Problem**: MCP servers show as disconnected after restore

**Solutions**:
1. Verify network connectivity: `ping server.example.com`
2. Test credentials manually: `ssh user@server.example.com`
3. Check server status: `claude mcp list`
4. Review debug logs: `tail -f ~/.claude/debug/*.txt`

### Permissions Not Working

**Problem**: Previously auto-approved commands now require approval

**Solution**:
- This is expected if you didn't restore `settings.local.json`
- Simply re-approve commands as you use them
- Claude Code will rebuild the permissions list
- Alternatively, restore from `settings.local.json.template`

### Git Won't Clone (Too Large)

**Problem**: Backup repository is very large

**Possible Causes**:
- Accidentally committed `history.jsonl` (can be hundreds of MB)
- Committed `debug/` logs

**Solution**:
```bash
# Remove large files from history
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch history.jsonl" \
  --prune-empty --tag-name-filter cat -- --all

# Force push
git push origin --force --all
```

### Different Behavior on New Machine

**Problem**: Claude Code behaves differently after restore

**Possible Reasons**:
1. Different Claude Code version
2. Different OS/platform
3. Project-specific settings (not backed up)
4. Local environment differences

**Check**:
```bash
# Verify Claude Code version
claude --version

# Compare settings
diff ~/.claude/settings.json ~/claude-code-settings-backup/settings.json
```

## FAQ

### Q: Do I need to backup chat history?

**A**: Usually not. Chat history (`history.jsonl`) can be very large and may contain sensitive information. If you want to preserve important conversations, export them individually rather than backing up the entire history file.

### Q: Can I share my backup repo publicly?

**A**: Only if you:
- Remove all credentials and sensitive data
- Remove all server names, IPs, and infrastructure details
- Keep only generic templates and instructions

Otherwise, use a **private repository**.

### Q: How often should I backup?

**A**: Backup when you make significant changes:
- Add new MCP servers
- Update global instructions (CLAUDE.md)
- Configure new permissions
- Change important settings

Consider creating a cron job or scheduled task for automatic backups.

### Q: Can I use this for team settings?

**A**: Yes! Create a shared private repository with:
- Team-wide global instructions
- Common MCP server configurations (without credentials)
- Shared permission patterns
- Team coding standards

Each team member clones and adds their own credentials locally.

### Q: What about project-specific CLAUDE.md files?

**A**: Project-specific `CLAUDE.md` files should be committed to the project repository, not your settings backup. They're meant to be shared with the team.

### Q: Will this work across different OS platforms?

**A**: Settings files are platform-agnostic. However:
- File paths may differ
- Some MCP servers may be OS-specific
- Test after restoring on a different platform

### Q: Can I automate backups?

**A**: Yes! See [scripts/auto-backup.sh](scripts/auto-backup.sh) for an example script you can run via cron or Task Scheduler.

## Additional Resources

- [Claude Code Documentation](https://docs.claude.com/claude-code)
- [Backup Script Template](scripts/backup.sh)
- [Restore Script Template](scripts/restore.sh)
- [MCP Server Restore Template](scripts/restore-mcp-template.sh)
- [Example .gitignore](templates/.gitignore)

## Contributing

Found an issue or have an improvement? Please:

1. Fork this repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - Feel free to use and modify as needed.

## Acknowledgments

Created by the Claude Code community to help users maintain their settings across machines.

---

**⚠️ Remember**: Never commit real passwords or API keys to Git, even in private repositories!
