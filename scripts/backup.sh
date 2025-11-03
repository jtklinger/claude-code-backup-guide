#!/bin/bash

# Claude Code Settings Backup Script
#
# This script backs up your Claude Code settings to a Git repository
# while sanitizing sensitive data like passwords and API keys.
#
# Usage: bash backup.sh [backup-directory]
#
# Example: bash backup.sh ~/claude-code-settings-backup

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default backup directory
BACKUP_DIR="${1:-$HOME/claude-code-settings-backup}"
CLAUDE_DIR="$HOME/.claude"

echo -e "${GREEN}Claude Code Settings Backup Script${NC}"
echo "===================================="
echo ""

# Check if Claude Code directory exists
if [ ! -d "$CLAUDE_DIR" ]; then
    echo -e "${RED}Error: Claude Code directory not found at $CLAUDE_DIR${NC}"
    echo "Please ensure Claude Code is installed."
    exit 1
fi

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${YELLOW}Creating backup directory: $BACKUP_DIR${NC}"
    mkdir -p "$BACKUP_DIR"
fi

cd "$BACKUP_DIR"

# Initialize git if not already initialized
if [ ! -d ".git" ]; then
    echo -e "${YELLOW}Initializing Git repository...${NC}"
    git init
    echo ""
fi

# Create .gitignore if it doesn't exist
if [ ! -f ".gitignore" ]; then
    echo -e "${YELLOW}Creating .gitignore...${NC}"
    cat > .gitignore << 'EOF'
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
*.swo
EOF
    echo "Created .gitignore"
    echo ""
fi

# Backup CLAUDE.md
if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
    echo -e "${GREEN}✓ Backing up CLAUDE.md${NC}"
    cp "$CLAUDE_DIR/CLAUDE.md" .
else
    echo -e "${YELLOW}⚠ CLAUDE.md not found (this is okay if you haven't created one)${NC}"
fi

# Backup settings.json
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    echo -e "${GREEN}✓ Backing up settings.json${NC}"
    cp "$CLAUDE_DIR/settings.json" .
else
    echo -e "${YELLOW}⚠ settings.json not found${NC}"
fi

# Backup and sanitize settings.local.json
if [ -f "$CLAUDE_DIR/settings.local.json" ]; then
    echo -e "${GREEN}✓ Backing up settings.local.json (sanitized)${NC}"

    # Sanitize passwords, API keys, and tokens
    cat "$CLAUDE_DIR/settings.local.json" | \
        sed 's/password="[^"]*"/password="YOUR_PASSWORD_HERE"/g' | \
        sed "s/password=''[^'']*''/password=''YOUR_PASSWORD_HERE''/g" | \
        sed "s/password='[^']*'/password='YOUR_PASSWORD_HERE'/g" | \
        sed 's/apiKey="[^"]*"/apiKey="YOUR_API_KEY"/g' | \
        sed 's/token="[^"]*"/token="YOUR_TOKEN"/g' | \
        sed 's/secret="[^"]*"/secret="YOUR_SECRET"/g' | \
        sed 's/key="[^"]*"/key="YOUR_KEY"/g' > \
        settings.local.json.template

    echo -e "${YELLOW}  → Saved as settings.local.json.template (passwords removed)${NC}"
else
    echo -e "${YELLOW}⚠ settings.local.json not found${NC}"
fi

# Export MCP server list
echo -e "${GREEN}✓ Exporting MCP server list${NC}"
if command -v claude &> /dev/null; then
    claude mcp list > mcp-servers.txt 2>&1 || true
    echo "  → Saved to mcp-servers.txt"
else
    echo -e "${YELLOW}  → Claude CLI not found, skipping MCP server export${NC}"
fi

# Create README if it doesn't exist
if [ ! -f "README.md" ]; then
    echo -e "${YELLOW}Creating README.md...${NC}"
    cat > README.md << 'EOF'
# Claude Code Settings Backup

This repository contains a backup of Claude Code settings.

## What's Included

- `CLAUDE.md` - Global instructions for Claude Code
- `settings.json` - Basic Claude Code settings
- `settings.local.json.template` - Permission templates (passwords removed)
- `mcp-servers.txt` - List of configured MCP servers

## Restoration

See the [Claude Code Backup Guide](https://github.com/jtklinger/claude-code-backup-guide) for complete instructions.

### Quick Restore

```bash
# Copy settings files
cp CLAUDE.md ~/.claude/
cp settings.json ~/.claude/

# Restore MCP servers (after editing with real credentials)
# See mcp-servers.txt for the list of servers to configure
```

## Security

⚠️ **IMPORTANT**: This backup has passwords removed for security.
- Never commit real passwords to Git
- Edit templates locally with real credentials when restoring
- Keep this repository private

## Last Updated

$(date '+%Y-%m-%d %H:%M:%S')
EOF
    echo "Created README.md"
fi

echo ""
echo -e "${GREEN}Backup Summary${NC}"
echo "=============="
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Files backed up:"
ls -lh CLAUDE.md settings.json settings.local.json.template mcp-servers.txt 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""

# Check for sensitive data
echo -e "${YELLOW}Security Check${NC}"
echo "==============="

# Function to check for patterns
check_sensitive() {
    local pattern=$1
    local description=$2
    local count=$(grep -i "$pattern" ./* 2>/dev/null | grep -v "YOUR_" | grep -v ".sh" | wc -l)

    if [ $count -gt 0 ]; then
        echo -e "${RED}⚠ Found $count potential $description in files!${NC}"
        echo "  Please review before committing."
        return 1
    else
        echo -e "${GREEN}✓ No $description found${NC}"
        return 0
    fi
}

all_clear=true
check_sensitive "password=" "passwords" || all_clear=false
check_sensitive "apiKey=" "API keys" || all_clear=false
check_sensitive "token=" "tokens" || all_clear=false

echo ""

if $all_clear; then
    echo -e "${GREEN}✓ Security check passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review the files in $BACKUP_DIR"
    echo "  2. Commit to Git:"
    echo "     cd $BACKUP_DIR"
    echo "     git add ."
    echo "     git commit -m 'Backup Claude Code settings'"
    echo "  3. Push to your private repository"
else
    echo -e "${RED}⚠ Security check found potential issues!${NC}"
    echo "Please review the files before committing."
    echo ""
    echo "Common issues:"
    echo "  - Passwords not properly sanitized"
    echo "  - API keys or tokens still present"
    echo "  - Secrets in permission patterns"
    echo ""
    echo "Review with:"
    echo "  grep -i 'password' $BACKUP_DIR/*"
    echo "  grep -i 'apiKey' $BACKUP_DIR/*"
fi

echo ""
echo -e "${GREEN}Backup complete!${NC}"
