#!/bin/bash

# Claude Code Settings Restore Script
#
# This script restores your Claude Code settings from a backup repository.
#
# Usage: bash restore.sh [backup-directory]
#
# Example: bash restore.sh ~/claude-code-settings-backup

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Backup directory (default to current directory)
BACKUP_DIR="${1:-.}"
CLAUDE_DIR="$HOME/.claude"

echo -e "${GREEN}Claude Code Settings Restore Script${NC}"
echo "====================================="
echo ""

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${RED}Error: Backup directory not found: $BACKUP_DIR${NC}"
    exit 1
fi

cd "$BACKUP_DIR"

# Create Claude directory if it doesn't exist
if [ ! -d "$CLAUDE_DIR" ]; then
    echo -e "${YELLOW}Creating Claude Code directory: $CLAUDE_DIR${NC}"
    mkdir -p "$CLAUDE_DIR"
fi

echo -e "${BLUE}Backup directory: $BACKUP_DIR${NC}"
echo -e "${BLUE}Claude directory: $CLAUDE_DIR${NC}"
echo ""

# Function to backup existing file
backup_existing() {
    local file=$1
    if [ -f "$CLAUDE_DIR/$file" ]; then
        local backup_name="$file.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}  → Backing up existing $file to $backup_name${NC}"
        cp "$CLAUDE_DIR/$file" "$CLAUDE_DIR/$backup_name"
    fi
}

# Restore CLAUDE.md
if [ -f "CLAUDE.md" ]; then
    echo -e "${GREEN}✓ Restoring CLAUDE.md${NC}"
    backup_existing "CLAUDE.md"
    cp CLAUDE.md "$CLAUDE_DIR/"
else
    echo -e "${YELLOW}⚠ CLAUDE.md not found in backup${NC}"
fi

# Restore settings.json
if [ -f "settings.json" ]; then
    echo -e "${GREEN}✓ Restoring settings.json${NC}"
    backup_existing "settings.json"
    cp settings.json "$CLAUDE_DIR/"
else
    echo -e "${YELLOW}⚠ settings.json not found in backup${NC}"
fi

# Handle settings.local.json
echo ""
echo -e "${BLUE}Settings.local.json Restoration${NC}"
echo "================================"

if [ -f "settings.local.json" ]; then
    # Real file exists (with credentials)
    echo -e "${YELLOW}Found settings.local.json (contains credentials)${NC}"
    echo ""
    echo "Options:"
    echo "  1) Restore it (if you've already added real credentials)"
    echo "  2) Skip (let Claude Code regenerate as you use it) [RECOMMENDED]"
    echo ""
    read -p "Choose option (1 or 2): " choice

    case $choice in
        1)
            backup_existing "settings.local.json"
            cp settings.local.json "$CLAUDE_DIR/"
            echo -e "${GREEN}✓ Restored settings.local.json${NC}"
            ;;
        2)
            echo -e "${YELLOW}Skipped settings.local.json (will be regenerated)${NC}"
            ;;
        *)
            echo -e "${YELLOW}Invalid choice, skipping${NC}"
            ;;
    esac
elif [ -f "settings.local.json.template" ]; then
    # Template exists (sanitized)
    echo -e "${YELLOW}Found settings.local.json.template (sanitized)${NC}"
    echo ""
    echo "This template has passwords replaced with placeholders."
    echo ""
    echo "Options:"
    echo "  1) Copy as template (you'll need to edit it manually later)"
    echo "  2) Skip (let Claude Code regenerate as you use it) [RECOMMENDED]"
    echo ""
    read -p "Choose option (1 or 2): " choice

    case $choice in
        1)
            cp settings.local.json.template "$CLAUDE_DIR/settings.local.json"
            echo -e "${YELLOW}✓ Copied template to settings.local.json${NC}"
            echo -e "${RED}  ⚠ IMPORTANT: Edit $CLAUDE_DIR/settings.local.json${NC}"
            echo -e "${RED}     and replace placeholders with real credentials!${NC}"
            ;;
        2)
            echo -e "${YELLOW}Skipped settings.local.json (will be regenerated)${NC}"
            ;;
        *)
            echo -e "${YELLOW}Invalid choice, skipping${NC}"
            ;;
    esac
else
    echo -e "${YELLOW}⚠ No settings.local.json or template found${NC}"
    echo "  Claude Code will generate this file as you approve commands."
fi

echo ""
echo -e "${BLUE}MCP Servers${NC}"
echo "==========="

if [ -f "mcp-servers.txt" ]; then
    echo -e "${GREEN}✓ Found MCP server list${NC}"
    echo ""
    echo "MCP servers to configure:"
    cat mcp-servers.txt | grep "ssh-mcp" | head -10 || echo "(List in mcp-servers.txt)"
    echo ""

    if [ -f "restore-mcp-servers.sh" ]; then
        echo -e "${YELLOW}Found restore-mcp-servers.sh script${NC}"
        echo ""
        echo "To restore MCP servers:"
        echo "  1. Edit restore-mcp-servers.sh and add your credentials"
        echo "  2. Run: bash restore-mcp-servers.sh"
        echo ""
        echo "Or configure manually using 'claude mcp add' commands"
    else
        echo "Configure MCP servers manually:"
        echo "  claude mcp add -s user --transport stdio SERVER_NAME -- \\"
        echo "    npx -y ssh-mcp --host=HOST --user=USER --password=PASSWORD"
        echo ""
        echo "See mcp-servers.txt for your server list."
    fi
else
    echo -e "${YELLOW}⚠ No MCP server list found${NC}"
fi

echo ""
echo -e "${GREEN}Restore Summary${NC}"
echo "==============="
echo ""
echo "Restored files:"
ls -lh "$CLAUDE_DIR"/{CLAUDE.md,settings.json,settings.local.json} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""

echo -e "${BLUE}Next Steps${NC}"
echo "=========="
echo ""
echo "1. Verify settings:"
echo "   cat $CLAUDE_DIR/CLAUDE.md"
echo "   cat $CLAUDE_DIR/settings.json"
echo ""
echo "2. If you restored settings.local.json:"
echo "   Review and edit: $CLAUDE_DIR/settings.local.json"
echo "   Replace placeholders with real credentials"
echo ""
echo "3. Configure MCP servers:"
echo "   See mcp-servers.txt for your server list"
echo "   Use restore-mcp-servers.sh or configure manually"
echo ""
echo "4. Restart Claude Code to apply settings"
echo ""
echo "5. Test that everything works:"
echo "   claude mcp list"
echo ""

echo -e "${GREEN}Restore complete!${NC}"
echo ""
echo -e "${YELLOW}Note: Some settings (like permissions) will be rebuilt${NC}"
echo -e "${YELLOW}as you use Claude Code. This is normal and expected.${NC}"
