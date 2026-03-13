# Atlassian MCP Lite for Cursor

Offloads Atlassian (Jira/Confluence) tool schemas from Cursor's active context window into a lightweight, local Gemini subagent. 

## Prerequisites
- Linux environment with `systemd`
- [uv](https://docs.astral.sh/uv/) installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`)

## Quickstart

1. **Configure Secrets**
   Fill out the `.env` file with your API tokens for both Atlassian and Gemini.

2. **Install**
   Run the installation script to configure the systemd background service and install the Python requirements:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```

3. **Reload Cursor**
   Reload your Cursor window to pick up the new `.mdc` rules.

4. **Usage**
   Cursor will automatically route Atlassian workflows to the subagent when you ask it to perform tasks like:
   - *"Break down this epic: TEAM-123"*
   - *"Draft my Friday update"* 
   - *"Find open bugs for me"*

## Data Flow & Configuration

Unlike standard MCP setups, this "Lite" version does **not** use a `mcp.json` file for Cursor registration. 

1. **Credentials:** The `mcp-atlassian` server reads Jira/Confluence credentials directly from your `.env` file.
2. **Background Service:** The `install.sh` script sets up a `systemd` user service that loads `.env` and runs the server on a local port (default: 8000).
3. **Subagent:** The `local_gemini_agent.py` script acts as the bridge. It connects to the server via HTTP/SSE, fetches the tool schemas, and executes them via a separate Gemini-powered ReAct loop.
4. **Context Purity:** This architecture ensures that hundreds of Atlassian tool schemas never "bloat" Cursor's primary context window, saving tokens and improving performance.

> [!IMPORTANT]
> **Windows/WSL Compatibility:** This project is designed for Linux environments (or WSL on Windows) due to its dependency on `systemd` and `bash`.
