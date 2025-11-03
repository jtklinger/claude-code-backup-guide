#!/bin/bash

# MCP Servers Restoration Template
#
# This is a TEMPLATE - you need to customize it for your servers.
#
# BEFORE USING:
# 1. Copy this file to your backup repository
# 2. Edit it to add your actual servers and credentials
# 3. Run it to restore all your MCP servers at once
#
# Usage: bash restore-mcp-servers.sh

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}MCP Servers Restoration${NC}"
echo "======================="
echo ""

# ============================================================================
# EDIT THESE VARIABLES
# ============================================================================

# If all your servers use the same password, set it here
# Otherwise, set it individually in each add_mcp_server call
COMMON_PASSWORD="YOUR_PASSWORD_HERE"

# ============================================================================
# HELPER FUNCTION
# ============================================================================

# Function to add an MCP server
add_mcp_server() {
    local name=$1
    local host=$2
    local user=$3
    local password=${4:-$COMMON_PASSWORD}  # Use common password if not specified
    local scope=${5:-user}  # Default to user scope (available in all projects)

    echo -e "${GREEN}Adding MCP server: $name${NC}"
    echo "  Host: $host"
    echo "  User: $user"
    echo "  Scope: $scope"

    claude mcp add -s "$scope" --transport stdio "$name" -- \
        npx -y ssh-mcp \
        --host="$host" \
        --user="$user" \
        --password="$password"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully added $name${NC}"
    else
        echo -e "${RED}✗ Failed to add $name${NC}"
    fi
    echo ""
}

# Alternative function for SSH key-based authentication
add_mcp_server_with_key() {
    local name=$1
    local host=$2
    local user=$3
    local key_path=$4
    local scope=${5:-user}

    echo -e "${GREEN}Adding MCP server (SSH key): $name${NC}"
    echo "  Host: $host"
    echo "  User: $user"
    echo "  Key: $key_path"
    echo "  Scope: $scope"

    claude mcp add -s "$scope" --transport stdio "$name" -- \
        npx -y ssh-mcp \
        --host="$host" \
        --user="$user" \
        --identity="$key_path"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully added $name${NC}"
    else
        echo -e "${RED}✗ Failed to add $name${NC}"
    fi
    echo ""
}

# ============================================================================
# VALIDATION
# ============================================================================

if [ "$COMMON_PASSWORD" == "YOUR_PASSWORD_HERE" ]; then
    echo -e "${RED}ERROR: You must edit this script first!${NC}"
    echo ""
    echo "Please edit this file and:"
    echo "  1. Set COMMON_PASSWORD (if all servers use same password)"
    echo "  2. Add your servers using add_mcp_server calls below"
    echo "  3. Remove this validation block"
    echo ""
    exit 1
fi

# ============================================================================
# ADD YOUR SERVERS HERE
# ============================================================================

# Example 1: SSH server with password
# add_mcp_server "my-server" "server.example.com" "myuser"

# Example 2: SSH server with different password
# add_mcp_server "special-server" "special.example.com" "admin" "different-password"

# Example 3: SSH server with key-based auth
# add_mcp_server_with_key "secure-server" "secure.example.com" "myuser" "/home/myuser/.ssh/id_ed25519"

# Example 4: Database server
# add_mcp_server "db-server" "db.example.com" "dbuser" "db-password"

# Example 5: Multiple servers with same credentials
# add_mcp_server "web1" "web1.example.com" "deploy"
# add_mcp_server "web2" "web2.example.com" "deploy"
# add_mcp_server "web3" "web3.example.com" "deploy"

# ============================================================================
# TEMPLATE EXAMPLES - DELETE THESE AND ADD YOUR OWN
# ============================================================================

# Uncomment and customize these examples:

# Production servers
# add_mcp_server "prod-web" "prod-web.example.com" "deploy"
# add_mcp_server "prod-db" "prod-db.example.com" "dbadmin"
# add_mcp_server "prod-cache" "prod-cache.example.com" "cacheadmin"

# Staging servers
# add_mcp_server "staging-web" "staging-web.example.com" "deploy"
# add_mcp_server "staging-db" "staging-db.example.com" "dbadmin"

# Development servers
# add_mcp_server "dev-server" "dev.example.com" "developer"

# Infrastructure servers
# add_mcp_server "dns-server" "ns1.example.com" "root"
# add_mcp_server "backup-server" "backup.example.com" "backupuser"

# ============================================================================
# VERIFICATION
# ============================================================================

echo -e "${GREEN}All MCP servers added!${NC}"
echo ""
echo "Verifying MCP servers..."
echo ""

claude mcp list

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "If any servers failed to add:"
echo "  1. Check the error messages above"
echo "  2. Verify credentials and network connectivity"
echo "  3. Try adding manually: claude mcp add ..."
