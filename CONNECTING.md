# Connecting RAD AI Bridge to an AI agent

RAD AI Bridge ships as a standard **stdio MCP server**, so it works with any
client that speaks the Model Context Protocol. This page gives the exact
configuration for the common ones.

> **Run `install.ps1` first.** Everything below assumes
> `McpServer\dist\index.js` exists. If it does not, see [README.md](README.md).

---

## The one thing every client needs

Whatever the client, you are telling it to run one command:

| | |
| --- | --- |
| **Command** | `node` |
| **Argument** | the full path to `McpServer\dist\index.js` |
| **Transport** | stdio (the default) |

The installer prints your exact path at the end. It looks like:

```
C:\Users\you\Documents\GitHub\RadAIBridge\McpServer\dist\index.js
```

### Two rules that trip everyone up

1. **Start RAD Studio before the agent.** The MCP server finds the IDE through
   `%APPDATA%\RadAiBridge\bridge.json`, which only exists while RAD Studio is
   running. If you start the agent first, its tools will fail until you restart
   it. (Restarting RAD Studio alone is fine — the server re-reads the file.)
2. **Escape the backslashes in JSON.** `C:\Users\...` must be written
   `C:\\Users\\...`. A single backslash is an escape character in JSON and will
   either break parsing or silently mangle the path. Forward slashes
   (`C:/Users/...`) also work and are less error-prone.

> Config file locations and schemas change between versions of these tools.
> If something below does not match what you see, check that vendor's current
> docs — but the `node` + path-to-`index.js` part never changes.

---

## Claude Code

The repository already contains a working `.mcp.json`, so if you open this repo
as your project folder, it just works.

To use it from **any** project, either add it to your user-level config, or run:

```bash
claude mcp add rad-ai-bridge --scope user -- node "C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"
```

Or write `.mcp.json` in your project root by hand:

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
    }
  }
}
```

Check it connected with `/mcp` inside Claude Code, or `claude mcp list` from a
terminal.

---

## Claude Desktop

Edit `%APPDATA%\Claude\claude_desktop_config.json` (create it if missing):

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
    }
  }
}
```

Fully quit and reopen Claude Desktop — closing the window is not enough, exit it
from the system tray. The tools then appear under the tools icon in the chat box.

---

## Cursor

Create `.cursor/mcp.json` in your project (or `~/.cursor/mcp.json` for every
project):

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
    }
  }
}
```

Then **Settings → MCP** and confirm the server shows as connected. Tools are
available in Agent mode.

---

## VS Code (GitHub Copilot agent mode)

Create `.vscode/mcp.json` in your workspace. Note the key here is `servers`, not
`mcpServers`:

```json
{
  "servers": {
    "rad-ai-bridge": {
      "type": "stdio",
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
    }
  }
}
```

Open Chat, switch to **Agent** mode, and the tools appear in the tools picker.

---

## Cline / Roo Code (VS Code extensions)

Open the extension's **MCP Servers** panel → **Configure MCP Servers**, which
opens its settings JSON:

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"],
      "disabled": false
    }
  }
}
```

Save; the extension reloads its servers automatically.

---

## Windsurf

**Settings → Cascade → MCP Servers → Add Server → raw config**, or edit
`~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
    }
  }
}
```

Press the refresh button in the MCP panel afterwards.

---

## Continue

In `config.yaml`:

```yaml
mcpServers:
  - name: rad-ai-bridge
    command: node
    args:
      - C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js
```

---

## Zed

In `settings.json`:

```json
{
  "context_servers": {
    "rad-ai-bridge": {
      "command": {
        "path": "node",
        "args": ["C:/Users/you/Documents/GitHub/RadAIBridge/McpServer/dist/index.js"]
      }
    }
  }
}
```

---

## Any other MCP client

Register a **stdio** server that runs `node <path>\McpServer\dist\index.js`.
It needs no environment variables, no arguments, no API key, and no network
access beyond a loopback TCP connection to the IDE.

To sanity-check the server by hand, MCP speaks line-delimited JSON-RPC on
stdin/stdout:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node .\McpServer\dist\index.js
```

A JSON blob listing the tools means the server is fine and the problem is in
your client's config.

---

## Testing without any agent at all

`IdePlugin\tools\call.js` talks straight to the IDE plugin, skipping MCP
entirely. This is the fastest way to tell whether a problem is in the IDE
plugin or in your agent setup:

```powershell
node .\IdePlugin\tools\call.js getProjectInfo
node .\IdePlugin\tools\call.js listOpenFiles
```

If these work, the plugin is healthy and any remaining fault is in the MCP
client configuration.

---

## Troubleshooting

**"No active project" / tools error but the server connected**
Normal. Open a project in RAD Studio.

**Tools do not appear in the agent at all**
The client never launched the server. Check the path in your config really
exists, and that backslashes are doubled (or use forward slashes). Most clients
have an MCP log panel that shows the launch error.

**Tools appear but every call fails**
RAD Studio is probably not running, or the plugin is not loaded. Check that
`%APPDATA%\RadAiBridge\bridge.json` exists. If it does not, open RAD Studio →
**Component → Install Packages** and confirm *RAD AI Bridge* is listed and
ticked.

**A call hangs and never returns**
Almost always a modal dialog in the IDE waiting for an answer — bridge calls run
on the IDE main thread, so a dialog blocks all of them. Look at RAD Studio.
Calls give up after 120 seconds with a message naming the likely cause. To find
and dismiss it from outside:

```powershell
.\IdePlugin\tools\dismiss-ide-modal.ps1              # what is showing?
.\IdePlugin\tools\dismiss-ide-modal.ps1 -Button No   # answer it
```

**`node` is not recognised**
Node.js is not on your PATH. Install the LTS build from
[nodejs.org](https://nodejs.org), then open a *new* terminal — PATH changes do
not apply to already-open windows. Some clients also need a full restart to
pick up a changed PATH.

**Two RAD Studio instances**
Only one is discoverable; the discovery file holds a single port. Close one.
