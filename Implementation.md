# The Atlassian Subagent Architecture Spec

## 1. Executive Summary: Solving Context Bloat
The core problem with standard Model Context Protocol (MCP) integrations in Cursor is **eager loading**. When the Atlassian MCP server is plugged directly into Cursor, it injects hundreds of massive, complex tool schemas (like `jira_get_issue`, `confluence_search`, etc.) into the LLM's system prompt for *every single interaction*. This causes severe token drain, high latency, and degraded reasoning (attention dilution).

This document outlines a revolutionary **Subagent Routing Architecture** that provides Cursor with full Atlassian capabilities while keeping the primary context window completely pristine. 

---

## 2. The Architectural Paradigm (The "Crazy Idea")

Instead of plugging the `mcp-atlassian` server directly into Cursor, we treat it as an isolated, standalone backend service. 

We then create a new, lightweight repository (the "Subagent Repo") consisting of two parts:
1. **The `.cursorrules` (.mdc) Skill Files:** Markdown files that teach the primary Cursor agent *when* and *how* to invoke Atlassian workflows.
2. **The Subagent Script (`local_gemini_agent.py`):** A lightweight Python script (using `smolagents`, `langchain`, or `google-genai`) that acts as an LLM middleman.

### How It Works:
1. The user asks Cursor: "Draft my weekly standup."
2. Cursor reads the `.cursorrules` skill and realizes it needs Atlassian data.
3. Cursor executes a terminal command: `uv run local_gemini_agent.py "Fetch tickets updated by me this week"`
4. The `local_gemini_agent.py` script spins up an ephemeral Gemini subagent.
5. **The Magic:** This Gemini subagent dynamically connects to the local `mcp-atlassian` server (running as a BACKGROUND process), pulls the tool schemas, executes a ReAct (Reasoning and Acting) loop to fetch the tickets, synthesizes the results, and prints a plain-text summary to **stdout**.
6. The subagent dies. Cursor reads the plain-text terminal output and presents it to the user.

**Architecture Note:** The subagent is NOT registered as an MCP server in Cursor. It is a pure CLI tool called by Cursor's skills to maintain 100% context purity.

---

## 3. Infrastructure & Deployment

The system is designed to run entirely on your remote development environment (e.g., Rocky Linux 8.9 VM) to prevent bridging issues when connecting via SSH from your laptop.

### A. The Atlassian MCP Server (Repo 1)
Instead of cloning and maintaining a local copy of the `mcp-atlassian` repository, we will use `uvx` to run the latest published package directly.
- **Hosting:** Run it continuously in the background using Linux `systemd`.
- **Systemd Config:**
  ```ini
  [Unit]
  Description=Atlassian MCP Server
  After=network.target

  [Service]
  Type=simple
  User=bethe
  WorkingDirectory=/home/bethe/
  ExecStart=/home/bethe/.cargo/bin/uvx mcp-atlassian@latest --transport streamable-http --port <PORT>
  Restart=always
  RestartSec=5

  [Install]
  WantedBy=multi-user.target
  ```

### B. The Subagent Middleware (Repo 2)
This is your new repository that contains the `.cursorrules` skills and the `local_gemini_agent.py` execution script. You drop this repository into whatever codebase you are actively developing in.

---

## 4. Secure Credential Management

Security is paramount. You **must never** commit Personal Access Tokens (PATs) into the `.mdc` skill files, as the LLM might leak them into prompts.

**The Solution: Strict `.env` Isolation**

We rely on a single, isolated `.env` file that is copied to the Subagent directory (`/home/user/atlassian-subagent/.env`) and ignored by git.

1. **Unified Secrets:** The `.env` file contains keys for both the Gemini Script and the systemd MCP server.
   ```ini
   # Gemini Subagent Configuration
   GEMINI_API_KEY=your_google_api_key
   
   # Connection Bridge: The port the server listens on (MCP_PORT)
   # and the URL the subagent uses to connect (MCP_SERVER_URL).
   MCP_PORT=8000
   MCP_SERVER_URL=http://localhost:8000/sse

   # Atlassian MCP Server Configuration
   ...
   ```

Because the MCP server handles all Jira API requests securely via `systemd` (which reads the EnvironmentFile), the Subagent script only handles LLM routing, and Cursor only handles terminal execution, **no tokens ever cross boundaries**.

## 4a. Configuration & Data Flow Details

Unlike typical MCP setups that use a `mcp.json` file for Cursor registration, this project uses a **direct environment-variable-based configuration**.

1.  **Direct-to-Process Credentials:** The `mcp-atlassian` server (launched via `uvx`) is designed to look for environment variables like `JIRA_URL` and `JIRA_API_TOKEN` in its process environment.
2.  **Environment Isolation:** We use a `.env` file as the single source for these variables.
3.  **The Systemd Bridge:** On Linux/WSL, we use a `systemd` user service with `EnvironmentFile=$TARGET_DIR/.env`. This ensures that every time the background server starts, it has the latest credentials without needing any external configuration files or being registered in Cursor.
4.  **Local SSE Connection:** The subagent (`local_gemini_agent.py`) connects to the background server via a local `MCP_SERVER_URL` (e.g., `http://localhost:8000/sse`), maintaining a clean separation of concerns.

---

## 5. The Advanced Skill Pipelines

These are the `.cursorrules` (.mdc) files you will place in your new repository. They explicitly instruct Cursor to offload complex workflows to the `local_gemini_agent.py` script.

### 1. Zero-Friction Sprint Grooming
* **Trigger:** "Break down this epic."
* **Workflow:** Cursor passes the Epic ID to the subagent. The subagent connects to the MCP, reads the Epic (`jira_get_issue`), uses Gemini to generate 5-10 logical sub-tasks, creates them (`jira_create_issue`), and links them to the parent. It returns a summary list to Cursor.

### 2. Automated Triage & Test Runner
* **Trigger:** "Find open bugs for me."
* **Workflow:** Cursor asks the subagent for bugs. The subagent runs a JQL search (`jira_search`) and returns the bug list. Cursor then runs tests locally in your workspace to reproduce the bug. Once complete, Cursor passes the terminal output back to the subagent to post as a comment (`jira_add_comment`) and move the ticket to 'In Progress'.

### 3. Living Documentation Sync
* **Trigger:** "Update docs for these code changes."
* **Workflow:** The developer provides a Confluence URL. Cursor passes the URL to the subagent to fetch the markdown (`confluence_get_page`). Cursor analyzes the old markdown against the new code changes in the IDE and writes a new markdown file locally. Cursor then tells the subagent to push the updated markdown file back to the wiki (`confluence_update_page`).

### 4. The PR Context Gatherer
* **Trigger:** "Give me context on this branch."
* **Workflow:** Cursor extracts the ticket ID from the branch name and passes it to the subagent. The subagent fetches the Jira description (`jira_get_issue`), reads linked PRDs from Confluence (`confluence_search`), and synthesizes a pure business-logic summary so the developer knows *why* the code was written before reviewing it.

### 5. Weekly Standup Summarizer
* **Trigger:** "Draft my Friday update."
* **Workflow:** Cursor asks the subagent to fetch the week's activity. The subagent runs `jira_search` for `assignee = currentUser() AND updated >= -7d`. It reads the tickets, synthesizes what was moved to "Done" versus what is "In Progress", and returns a clean, bulleted markdown summary to Cursor.

### 6. Duplicate Bug Hunter & Linker
* **Trigger:** "Triage this new bug."
* **Workflow:** Cursor passes an error stack trace to the subagent. The subagent runs semantic searches across the Jira backlog (`jira_search`). If it finds a match, the subagent automatically links the tickets (`jira_create_issue_link`), leaves a comment, transitions the new bug to closed, and informs Cursor that the bug was a duplicate.

### 7. Automated Backlog Assassin
* **Trigger:** "Clean up the backlog for [Feature]."
* **Workflow:** Cursor passes the feature name to the subagent. The subagent finds all open technical debt or requests mentioning it, drops an automated comment ("Obsoleted by recent PR"), bulk-transitions them to 'Closed', and returns a "kill list" of closed tickets to Cursor.

### 8. Code Archaeologist (@CodeArchaeologist)
* **Trigger:** Highlighting a block of legacy code and invoking the skill.
* **Workflow:** 
  1. Cursor natively runs `git blame` and `git log` on the highlighted snippet to extract the Jira ticket ID from the commit message.
  2. Cursor passes that ID to the subagent.
  3. The subagent fetches the main ticket, and strictly limits itself to fetching a maximum of 3 linked Parent Epics or Blocking tickets.
  4. The subagent synthesizes "The Origin", "The Git Context", "The Why", "The Blast Radius", and "Historical Quirks".
  5. The plain-text archaeology report is displayed to the user.

---

## 6. Summary of Benefits
By isolating the `mcp-atlassian` server behind a local LLM Subagent middleware:
1. **Cursor Context Remains Pure:** Zero tool schemas pollute your primary coding context.
2. **Infinite Upgradability:** By using `uvx mcp-atlassian@latest`, the server will automatically pull and run the most up-to-date version of the Atlassian MCP package without requiring manual code pulls or rebuilds.
3. **High Security:** `.env` isolation guarantees Cursor never accidentally leaks your PATs.
4. **Resilient Infrastructure:** `systemd` ensures the MCP bridge is always available 24/7 on your dev VM.
