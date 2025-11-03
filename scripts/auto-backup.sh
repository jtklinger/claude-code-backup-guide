#!/bin/bash

# Claude Code Automatic Backup Script
#
# This script automatically backs up Claude Code settings and commits to Git.
# Use this with cron (Linux/macOS) or Task Scheduler (Windows) for automatic backups.
#
# Usage: bash auto-backup.sh [backup-directory]
#
# Cron example (backup daily at 2 AM):
#   0 2 * * * /path/to/auto-backup.sh /path/to/backup-repo >> /var/log/claude-backup.log 2>&1
#
# Windows Task Scheduler:
#   Program: C:\Program Files\Git\bin\bash.exe
#   Arguments: C:\path\to\auto-backup.sh C:\path\to\backup-repo

set -e  # Exit on error

# Configuration
BACKUP_DIR="${1:-$HOME/claude-code-settings-backup}"
CLAUDE_DIR="$HOME/.claude"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Logging function
log() {
    echo "$LOG_PREFIX $1"
}

log_error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
}

# Check if Claude Code directory exists
if [ ! -d "$CLAUDE_DIR" ]; then
    log_error "Claude Code directory not found at $CLAUDE_DIR"
    exit 1
fi

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    log "Creating backup directory..."
    mkdir -p "$BACKUP_DIR"
fi

cd "$BACKUP_DIR"

# Check if it's a git repository
if [ ! -d ".git" ]; then
    log_error "Not a git repository: $BACKUP_DIR"
    log "Run backup.sh first to initialize the backup"
    exit 1
fi

log "Starting automatic backup..."

# Track if anything changed
CHANGES_MADE=false

# Backup CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    if ! cmp -s "$CLAUDE_DIR/CLAUDE.md" "CLAUDE.md" 2>/dev/null; then
        log "Backing up CLAUDE.md (changed)"
        cp "$CLAUDE_DIR/CLAUDE.md" .
        CHANGES_MADE=true
    fi
fi

# Backup settings.json
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    if ! cmp -s "$CLAUDE_DIR/settings.json" "settings.json" 2>/dev/null; then
        log "Backing up settings.json (changed)"
        cp "$CLAUDE_DIR/settings.json" .
        CHANGES_MADE=true
    fi
fi

# Backup and sanitize settings.local.json
if [ -f "$CLAUDE_DIR/settings.local.json" ]; then
    cat "$CLAUDE_DIR/settings.local.json" | \
        sed 's/password="[^"]*"/password="YOUR_PASSWORD_HERE"/g' | \
        sed "s/password=''[^'']*''/password=''YOUR_PASSWORD_HERE''/g" | \
        sed "s/password='[^']*'/password='YOUR_PASSWORD_HERE'/g" | \
        sed 's/apiKey="[^"]*"/apiKey="YOUR_API_KEY"/g' | \
        sed 's/token="[^"]*"/token="YOUR_TOKEN"/g' | \
        sed 's/secret="[^"]*"/secret="YOUR_SECRET"/g' | \
        sed 's/key="[^"]*"/key="YOUR_KEY"/g' > \
        settings.local.json.template.new

    if ! cmp -s settings.local.json.template.new settings.local.json.template 2>/dev/null; then
        log "Backing up settings.local.json (changed)"
        mv settings.local.json.template.new settings.local.json.template
        CHANGES_MADE=true
    else
        rm -f settings.local.json.template.new
    fi
fi

# Export MCP server list
if command -v claude &> /dev/null; then
    claude mcp list > mcp-servers.txt.new 2>&1 || true

    if ! cmp -s mcp-servers.txt.new mcp-servers.txt 2>/dev/null; then
        log "Updating MCP server list (changed)"
        mv mcp-servers.txt.new mcp-servers.txt
        CHANGES_MADE=true
    else
        rm -f mcp-servers.txt.new
    fi
fi

# Security check before committing
log "Running security check..."
SECURITY_ISSUES=0

# Check for passwords
if grep -i "password=" ./* 2>/dev/null | grep -v "YOUR_PASSWORD_HERE" | grep -v ".sh" | grep -q .; then
    log_error "Found real passwords in files!"
    SECURITY_ISSUES=$((SECURITY_ISSUES + 1))
fi

# Check for API keys
if grep -i "apiKey=" ./* 2>/dev/null | grep -v "YOUR_API_KEY" | grep -v ".sh" | grep -q .; then
    log_error "Found real API keys in files!"
    SECURITY_ISSUES=$((SECURITY_ISSUES + 1))
fi

# Check for tokens
if grep -i "token=" ./* 2>/dev/null | grep -v "YOUR_TOKEN" | grep -v ".sh" | grep -q .; then
    log_error "Found real tokens in files!"
    SECURITY_ISSUES=$((SECURITY_ISSUES + 1))
fi

if [ $SECURITY_ISSUES -gt 0 ]; then
    log_error "Security check failed! Not committing."
    log_error "Found $SECURITY_ISSUES potential security issues."
    exit 1
fi

log "Security check passed"

# Commit changes if any
if [ "$CHANGES_MADE" = true ]; then
    log "Changes detected, committing to git..."

    git add CLAUDE.md settings.json settings.local.json.template mcp-servers.txt 2>/dev/null || true

    # Check if there are actually staged changes
    if ! git diff --cached --quiet 2>/dev/null; then
        COMMIT_MSG="Auto-backup Claude Code settings - $(date '+%Y-%m-%d %H:%M:%S')"

        git commit -m "$COMMIT_MSG" || {
            log_error "Git commit failed"
            exit 1
        }

        log "Committed changes: $COMMIT_MSG"

        # Try to push to remote (optional, comment out if you don't want auto-push)
        if git remote get-url origin &>/dev/null; then
            log "Pushing to remote..."
            if git push origin main 2>&1; then
                log "Successfully pushed to remote"
            else
                # Try master branch if main fails
                if git push origin master 2>&1; then
                    log "Successfully pushed to remote (master branch)"
                else
                    log_error "Failed to push to remote (this is non-fatal)"
                    log "You can manually push later: cd $BACKUP_DIR && git push"
                fi
            fi
        else
            log "No remote configured, skipping push"
        fi
    else
        log "No actual changes to commit (files identical)"
    fi
else
    log "No changes detected, skipping commit"
fi

log "Automatic backup complete"

# Print summary
log "Backup location: $BACKUP_DIR"
log "Last commit: $(git log -1 --format='%h - %s (%ar)' 2>/dev/null || echo 'No commits yet')"
