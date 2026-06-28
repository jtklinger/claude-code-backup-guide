#!/bin/bash

# Claude Code Backup — First-Time Setup Script
#
# Initializes a backup repository by scanning ~/.claude/projects/,
# letting you select which projects to include, and generating
# backup-config.json.
#
# Usage: bash init.sh [backup-directory]
#
# Example: bash init.sh ~/claude-code-backup

set -e

SCRIPT_VERSION="2.4.0"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Resolve the directory where this script lives (for finding templates)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)" || REPO_ROOT=""

# Backup directory: argument > current directory
BACKUP_DIR="${1:-.}"
BACKUP_DIR="$(cd "$BACKUP_DIR" 2>/dev/null && pwd)" || {
    # Directory doesn't exist yet — resolve the absolute path and create it
    BACKUP_DIR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    mkdir -p "$BACKUP_DIR"
}

CLAUDE_DIR="$HOME/.claude"

echo -e "${GREEN}Claude Code Backup — Init v${SCRIPT_VERSION}${NC}"
echo "==================================="
echo ""

# ─── Pre-flight checks ───────────────────────────────────────────────

# Check that ~/.claude/ exists
if [ ! -d "$CLAUDE_DIR" ]; then
    echo -e "${RED}Error: Claude Code directory not found at $CLAUDE_DIR${NC}"
    echo "Please install and run Claude Code at least once before setting up backups."
    exit 1
fi
echo -e "${GREEN}[ok]${NC} Found Claude Code directory: $CLAUDE_DIR"

# Check for jq (needed by backup.sh, not by this script)
if command -v jq &>/dev/null; then
    echo -e "${GREEN}[ok]${NC} jq is available ($(jq --version 2>&1))"
else
    echo -e "${YELLOW}[warn]${NC} jq is not installed. backup.sh requires jq to read config."
    echo "       Install it before running backups:"
    echo "         macOS:   brew install jq"
    echo "         Linux:   sudo apt install jq  /  sudo dnf install jq"
    echo "         Windows: winget install jqlang.jq  /  scoop install jq"
fi

echo ""

# ─── Git repo setup ──────────────────────────────────────────────────

echo -e "${GREEN}Setting up backup directory:${NC} $BACKUP_DIR"
echo ""

if [ ! -d "$BACKUP_DIR/.git" ]; then
    echo -e "${YELLOW}Initializing git repository...${NC}"
    git init "$BACKUP_DIR"
    echo ""
else
    echo -e "${GREEN}[ok]${NC} Git repository already initialized"
fi

# Copy .gitignore from templates if none exists in the backup dir
if [ ! -f "$BACKUP_DIR/.gitignore" ]; then
    TEMPLATE_GITIGNORE=""
    # Look relative to the script location first
    if [ -f "$REPO_ROOT/templates/.gitignore" ]; then
        TEMPLATE_GITIGNORE="$REPO_ROOT/templates/.gitignore"
    # Then look in the backup directory itself
    elif [ -f "$BACKUP_DIR/templates/.gitignore" ]; then
        TEMPLATE_GITIGNORE="$BACKUP_DIR/templates/.gitignore"
    fi

    if [ -n "$TEMPLATE_GITIGNORE" ]; then
        cp "$TEMPLATE_GITIGNORE" "$BACKUP_DIR/.gitignore"
        echo -e "${GREEN}[ok]${NC} Copied .gitignore from template"
    else
        echo -e "${YELLOW}[warn]${NC} No template .gitignore found — creating a minimal one"
        printf '%s\n' \
            "# Credentials" \
            ".credentials.json" \
            "*.key" \
            "*.pem" \
            ".env" \
            ".env.*" \
            "" \
            "# Temporary files" \
            "*.tmp" \
            "*.bak" \
            "*.swp" \
            "*~" \
            "" \
            "# OS files" \
            ".DS_Store" \
            "Thumbs.db" \
            "desktop.ini" \
            > "$BACKUP_DIR/.gitignore"
    fi
else
    echo -e "${GREEN}[ok]${NC} .gitignore already exists"
fi

echo ""

# ─── Scan projects ───────────────────────────────────────────────────

PROJECTS_DIR="$CLAUDE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
    echo -e "${YELLOW}No projects directory found at $PROJECTS_DIR${NC}"
    echo "Generating config with an empty project list."
    echo "You can add projects to backup-config.json later."
    SELECTED_PROJECTS=()
else
    # Collect project directory names (immediate children only)
    PROJECT_NAMES=()
    PROJECT_DISPLAY=()

    while IFS= read -r dir_name; do
        [ -z "$dir_name" ] && continue
        PROJECT_NAMES+=("$dir_name")

        # Convert hash name to human-readable path:
        #   C--Users-jtkli-projects-Homelab  ->  C:/Users/jtkli/projects/Homelab
        # Step 1: Replace leading "C--" with "C:/"
        readable="$dir_name"
        readable="$(echo "$readable" | sed 's/^C--/C:\//')"
        # Step 2: Replace all remaining "--" with "/"
        readable="$(echo "$readable" | sed 's/--/\//g')"
        # Step 3: Replace remaining single "-" with "/" for path separators
        # Actually, single dashes ARE path separators in the Claude hash scheme
        readable="$(echo "$readable" | sed 's/-/\//g')"

        PROJECT_DISPLAY+=("$readable")
    done < <(ls -1 "$PROJECTS_DIR" 2>/dev/null)

    if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No projects found under $PROJECTS_DIR${NC}"
        SELECTED_PROJECTS=()
    else
        echo -e "${GREEN}Found ${#PROJECT_NAMES[@]} project(s) in $PROJECTS_DIR:${NC}"
        echo ""

        for i in "${!PROJECT_NAMES[@]}"; do
            num=$((i + 1))
            echo "  $num) ${PROJECT_DISPLAY[$i]}"
            echo "     (${PROJECT_NAMES[$i]})"
        done

        echo ""
        echo "Enter project numbers to include, separated by spaces."
        echo "Type 'all' to include everything, or 'none' to skip."
        echo ""
        printf "Selection: "
        read -r selection

        SELECTED_PROJECTS=()

        if [ -z "$selection" ] || [ "$selection" = "all" ]; then
            SELECTED_PROJECTS=("${PROJECT_NAMES[@]}")
            echo -e "${GREEN}Selected all ${#PROJECT_NAMES[@]} project(s).${NC}"
        elif [ "$selection" = "none" ]; then
            SELECTED_PROJECTS=()
            echo -e "${YELLOW}No projects selected.${NC}"
        else
            for num in $selection; do
                # Validate: must be a number in range
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#PROJECT_NAMES[@]} ]; then
                    idx=$((num - 1))
                    SELECTED_PROJECTS+=("${PROJECT_NAMES[$idx]}")
                else
                    echo -e "${YELLOW}Skipping invalid selection: $num${NC}"
                fi
            done
            echo -e "${GREEN}Selected ${#SELECTED_PROJECTS[@]} project(s).${NC}"
        fi
    fi
fi

echo ""

# ─── Generate backup-config.json ─────────────────────────────────────

CONFIG_FILE="$BACKUP_DIR/backup-config.json"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}backup-config.json already exists at $CONFIG_FILE${NC}"
    printf "Overwrite? [y/N]: "
    read -r overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "Keeping existing config. Done."
        exit 0
    fi
fi

# Build the projects JSON array using printf (no jq dependency)
PROJECTS_JSON=""
for i in "${!SELECTED_PROJECTS[@]}"; do
    if [ "$i" -gt 0 ]; then
        PROJECTS_JSON="$PROJECTS_JSON,"
    fi
    PROJECTS_JSON="$PROJECTS_JSON
    \"${SELECTED_PROJECTS[$i]}\""
done

# Write the config file
printf '%s\n' "{
  \"version\": 1,
  \"claude_dir\": \"~/.claude\",
  \"include_sessions\": true,
  \"include_todos\": true,
  \"projects\": [$PROJECTS_JSON
  ],
  \"git_auto_push\": false,
  \"git_remote\": \"origin\",
  \"git_branch\": \"main\"
}" > "$CONFIG_FILE"

echo -e "${GREEN}[ok]${NC} Generated backup-config.json"
echo ""

# ─── Summary & next steps ────────────────────────────────────────────

echo -e "${GREEN}Setup complete!${NC}"
echo "=============================="
echo ""
echo "Backup directory: $BACKUP_DIR"
echo "Config file:      $CONFIG_FILE"
echo "Projects:         ${#SELECTED_PROJECTS[@]} selected"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo ""
echo "  1. Run your first backup:"
echo "     bash $SCRIPT_DIR/backup.sh $BACKUP_DIR"
echo ""
echo "  2. Add a Git remote (private repo recommended):"
echo "     cd $BACKUP_DIR"
echo "     git remote add origin git@github.com:YOUR_USER/claude-backup.git"
echo ""
echo "  3. Schedule automatic backups:"
echo ""
echo "     Linux/macOS (cron):"
echo "       0 2 * * * $SCRIPT_DIR/backup.sh $BACKUP_DIR"
echo ""
echo "     Windows (Task Scheduler):"
echo "       Program:   C:\\Program Files\\Git\\bin\\bash.exe"
echo "       Arguments: $SCRIPT_DIR/backup.sh $BACKUP_DIR"
echo ""
echo "  4. To enable auto-push after each backup, edit backup-config.json"
echo "     and set \"git_auto_push\": true"
echo ""
