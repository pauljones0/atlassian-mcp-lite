#!/bin/bash

# Configuration
TARGET_DIR="$HOME/atlassian-subagent"
SERVICE_NAME="atlassian-mcp.service"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Atlassian MCP Lite Setup...${NC}"

# 1. Check prerequisites
if ! command -v uvx &> /dev/null; then
    echo -e "${YELLOW}Warning: 'uvx' (or 'uv') is not installed. Please install it first: curl -LsSf https://astral.sh/uv/install.sh | sh${NC}"
    exit 1
fi

# Check for jq, install if missing
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}'jq' not found. Attempting to install...${NC}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
    elif command -v brew &> /dev/null; then
        brew install jq
    else
        echo -e "${YELLOW}Warning: Could not automatically install 'jq'. Please install it manually.${NC}"
        exit 1
    fi
fi

# 2. Create target directories
echo -e "${GREEN}Creating Subagent directory at ${TARGET_DIR}...${NC}"
mkdir -p "$TARGET_DIR"

# 3. Copy files to target directory
echo -e "${GREEN}Copying subagent files...${NC}"
cp local_gemini_agent.py "$TARGET_DIR/"
if [ -f ".env" ]; then
    cp .env "$TARGET_DIR/.env"
else
    echo -e "${YELLOW}Warning: source .env not found.${NC}"
fi

# 4. Setup systemd service for the Atlassian MCP Server
echo -e "${GREEN}Setting up systemd service (${SERVICE_NAME})...${NC}"
mkdir -p "$SYSTEMD_DIR"

# Extract port from .env or default to 8000
TARGET_PORT=$(grep MCP_PORT "$TARGET_DIR/.env" | cut -d '=' -f2 | tr -d ' \r\n')
if [ -z "$TARGET_PORT" ]; then TARGET_PORT="8000"; fi
echo -e "${GREEN}Detected MCP Server Port: ${TARGET_PORT}${NC}"

cat << EOF > "$SYSTEMD_DIR/$SERVICE_NAME"
[Unit]
Description=Atlassian MCP Server
After=network.target

[Service]
Type=simple
EnvironmentFile=$TARGET_DIR/.env
WorkingDirectory=$HOME
ExecStart=$(which uvx) mcp-atlassian@latest --transport streamable-http --port $TARGET_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Ensure user systemd process starts
loginctl enable-linger "$USER"

# Reload daemon and start
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

echo -e "${GREEN}Atlassian MCP Server is now running on port ${TARGET_PORT}.${NC}"

# 6. Install Subagent Python Requirements
echo -e "${GREEN}Installing Subagent Python dependencies using uv...${NC}"
cd "$TARGET_DIR"
uv venv
source .venv/bin/activate
uv pip install google-genai mcp langchain

# 7. Copy Cursor Rules
echo -e "${GREEN}Copying Cursor Rules to ~/.cursor/rules...${NC}"
mkdir -p "$HOME/.cursor/rules"
cp rules/*.mdc "$HOME/.cursor/rules/"

# 8. Setup Complete
echo -e "${GREEN}--- Setup Complete ---${NC}"
echo -e "Next steps:"
echo -e "1. Edit $HOME/.env with your Atlassian API tokens."
echo -e "2. Edit $TARGET_DIR/.env with your Gemini API key."
echo -e "3. Reload Cursor to pick up the new .mdc rules."
