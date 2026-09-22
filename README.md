# RAD AI Bridge

Lets an AI coding agent (Claude Code, Cursor, Cline, Copilot agent mode — anything
that speaks MCP) drive a **running RAD Studio IDE**: read and write live editor
buffers, manage project files, build with structured error output, drive the
debugger, and inspect or edit the FMX/VCL form Designer's component tree.

Not a code generator that writes files and hopes. It talks to the IDE you already
have open, through the Open Tools API, so the agent sees exactly what you see —
the same buffers, the same project, the same debug session.

```
┌─────────────┐   stdio    ┌────────────┐   TCP/JSON   ┌──────────────────┐
│  Your agent │ ─────────► │ MCP server │ ───────────► │ RadAiBridge.bpl  │
│             │            │  (Node.js) │   loopback   │ inside RAD Studio│
└─────────────┘            └────────────┘              └──────────────────┘
```

Two pieces:

- **`IdePlugin/`** — a Delphi Open Tools API package (`RadAiBridge.bpl`) that loads
  into RAD Studio and runs a small JSON-RPC server on a loopback TCP socket. No UI,
  no menu entry.
- **`McpServer/`** — a Node.js MCP server launched over stdio. It reads the plugin's
  published port and forwards MCP tool calls to it.

Windows only, because RAD Studio is.
Developed and verified against **RAD Studio 13 (Delphi 37.0)**.

---

# Installation

## Before you start

You need:

- **RAD Studio / Delphi**, any edition that includes the command-line compiler
  (`dcc32.exe`) and `designide`. The installer finds it for you.
- **Node.js 18 or newer** — [nodejs.org](https://nodejs.org), take the LTS build.
  Tick "Add to PATH" during setup (it is on by default).
- **An MCP-capable AI agent**, e.g. Claude Code, Claude Desktop, Cursor, Cline,
  Windsurf, or VS Code with Copilot agent mode.

You do **not** need Administrator rights, Git Bash, WSL, or any Delphi knowledge.

## Step 1 — Get the files

If you have Git:

```powershell
git clone https://github.com/AdriaanBoshoff/RadAIBridge.git
cd RadAIBridge
```

If you do not: click **Code → Download ZIP** on GitHub, then extract it somewhere
permanent (for example `C:\Tools\RadAIBridge`). Do not run it from inside the ZIP,
and avoid a OneDrive-synced folder.

> **If you downloaded the ZIP**, Windows marks the files as "from the internet" and
> PowerShell will refuse to run them. Unblock them once:
>
> ```powershell
> Get-ChildItem -Recurse | Unblock-File
> ```

## Step 2 — Run the installer

Open **PowerShell** in the folder you just created (Shift + right-click the folder
→ *Open PowerShell window here*), and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> Why `-ExecutionPolicy Bypass`? Windows blocks PowerShell scripts by default.
> This allows just this one run, and changes no settings on your machine. If you
> would rather not, `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, and
> afterwards `.\install.ps1` works on its own.

The installer walks through seven steps and tells you what it is doing at each one:

```
[1/7] Looking for RAD Studio          finds your install, asks which if several
[2/7] Checking Node.js                 verifies version 18+
[3/7] Making sure RAD Studio is closed asks before closing anything
[4/7] Compiling the IDE plugin (Win32) runs dcc32
[5/7] Registering the package          writes to HKCU, no admin needed
[6/7] Building the MCP server          npm install + npm run build
[7/7] Starting RAD Studio              waits until the bridge reports in
```

A successful run ends with the live port and the exact config to paste into your
agent:

```
      Bridge is live: {"port":49452,"pid":45112,"version":"1"}

Installed.
```

**It will offer to close RAD Studio.** It has to: a `.bpl` that a running IDE has
mapped cannot be safely replaced. Save your work before answering yes.

Useful switches:

| Switch | Effect |
| --- | --- |
| `-BdsVersion 37.0` | Pick a RAD Studio version without being asked |
| `-SkipMcpServer` | Build only the IDE plugin |
| `-NoStart` | Do not launch RAD Studio at the end |
| `-CloseIde` | Close a running IDE without asking (unattended installs) |

## Step 3 — Connect your agent

The installer prints a ready-made config block. For Claude Code, put this in
`.mcp.json` in your project folder:

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

**[CONNECTING.md](CONNECTING.md) has step-by-step config for Claude Code, Claude
Desktop, Cursor, VS Code / Copilot, Cline, Roo Code, Windsurf, Continue, Zed, and
any other MCP client**, plus troubleshooting.

Two rules worth knowing now:

1. **Start RAD Studio before your agent.** The MCP server locates the IDE through a
   file that only exists while RAD Studio is running.
2. **In JSON, write `C:\\Users\\...` or `C:/Users/...`** — a single backslash is an
   escape character and will break the path.

## Step 4 — Install the agent skill (recommended)

`skills/rad-ai-bridge/SKILL.md` teaches the agent how to use these tools well —
tool ordering, batching, and how to avoid the IDE dialogs that block every call.
For Claude Code:

```powershell
Copy-Item -Recurse -Force .\skills\rad-ai-bridge $env:USERPROFILE\.claude\skills\
```

See [skills/README.md](skills/README.md) for other agents.

## Step 5 — Check it works

Open a project in RAD Studio, then ask your agent something like *"what project is
open in RAD Studio?"*. It should answer using `getProjectInfo`.

If not, test the plugin directly, bypassing the agent entirely:

```powershell
node .\IdePlugin\tools\call.js getProjectInfo
```

If that works, the plugin is fine and the problem is your agent's MCP config — see
[CONNECTING.md](CONNECTING.md). If it does not, the plugin did not load: in RAD
Studio check **Component → Install Packages** for *RAD AI Bridge*.

## Uninstalling

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Unregisters the package from every RAD Studio version and removes the discovery
file. Add `-DeleteBuildOutput` to also delete compiled output. Your copy of the
repository is left alone — delete the folder yourself.

## Updating

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

---

# Tool reference

41 tools:

| Area | Tools |
| --- | --- |
| **Editor** | `getEditorContent`, `getEditorLines`, `setEditorContent`, `applyEdit`, `openFile`, `listOpenFiles` |
| **Project** | `getProjectInfo`, `openProject`, `addFileToProject`, `removeFileFromProject`, `setProjectPlatform`, `listBuildConfigurations`, `listProjectOptions`, `getProjectOption`, `setProjectOption` |
| **Creation** | `createProject`, `createUnit`, `createForm`, `addUsesUnit` |
| **Build** | `compileProject` |
| **Designer** | `getFormTree`, `addComponent`, `deleteComponent`, `selectComponent`, `getComponentProperties`, `setComponentProperty`, `setComponentProperties`, `setComponentEvent` |
| **Debugger** | `runProject`, `stepOver`, `stepInto`, `stepOut`, `runToCursor`, `terminateProcess`, `addBreakpoint`, `removeBreakpoint`, `removeAllBreakpoints`, `listBreakpoints`, `getCallStack`, `evaluateExpression` |
| **Diagnostics** | `listIdeActions` |

`McpServer/src/index.ts` carries the authoritative list with full parameter
descriptions.

---

# Developing the bridge itself

## Rebuild loop

A `.bpl` cannot hot-reload, so every plugin change needs a full IDE restart:

```powershell
.\IdePlugin\rebuild.ps1
```

Compiles, closes the IDE, deploys, restarts, and waits until the bridge reports in.
`rebuild.sh` is the same thing for Git Bash/WSL, if you prefer it — but nothing in
this project requires bash.

**Never copy over a deployed `.bpl` while an IDE has it mapped.** The copy appears
to succeed but leaves an image the next IDE start silently fails to load — no error
dialog, the package simply never appears in the process. Both rebuild scripts close
the IDE first to make that impossible. To check whether it loaded:

```powershell
(Get-Process bds).Modules | Where-Object ModuleName -like '*RadAi*'
```

## Talking to the plugin without an agent

`IdePlugin/tools/call.js` drives the RPC socket directly. An MCP client usually
cannot be made to reconnect on demand, so without this, every plugin change would
need an agent restart just to exercise one tool.

```powershell
node .\IdePlugin\tools\call.js getProjectInfo
node .\IdePlugin\tools\call.js addBreakpoint 'filePath=C:\src\MainFormU.pas' line=74
node .\IdePlugin\tools\call.js getCallStack maxFrames=8
```

Parameters are `key=value`, parsed as JSON where that succeeds and kept as plain
strings otherwise — so Windows paths need no escaping.

## When a call hangs

```powershell
.\IdePlugin\tools\dismiss-ide-modal.ps1              # report what is showing
.\IdePlugin\tools\dismiss-ide-modal.ps1 -Button No   # click a button
```

---

# Known limitations

- **Any modal dialog in the IDE blocks every bridge call.** Tool handlers run on the
  IDE main thread, so while a dialog is up, calls queue until it is dismissed. They
  fail after 120s with a message naming the likely cause rather than hanging
  forever. Common culprits: *"Source has been modified. Rebuild?"*, third-party
  wizards that prompt on component creation (CnPack's component-name dialog is a
  frequent one), and unsaved project groups. Routing work through a posted window
  message instead of `TThread.Synchronize` does **not** avoid this — a modal's own
  message loop does not dispatch the posted work.
- **One IDE instance at a time.** The discovery file holds a single port; a second
  instance overwrites it. Shutdown is at least PID-checked, so an instance closing
  will not delete a newer instance's entry.
- **The plugin is Win32 only.** `bds.exe` is a 32-bit process, so design-time
  packages must match it. This has no bearing on what platforms *your* projects
  target.
- **`compileProject` shells out to `msbuild`** via `rsvars.bat` rather than using the
  IDE's internal message view, whose API is thinly documented. Clean structured
  errors, slightly slower than an in-process build. It runs off the main thread so
  the IDE stays responsive, and full `msbuild` output is returned only on request
  (`includeRawOutput: true`) or when a failure could not be parsed.
- `runToCursor` depends on the editor's current caret position, which the bridge does
  not set for you.

---

# Notes for anyone extending this

A few things cost real time to work out. They are commented in the source, but are
worth repeating:

- `IOTAProjectCreator.GetFileName` must return the **`.dpr`**, never the `.dproj`.
  The IDE resolves the project-type handler from that extension, and a `.dproj`
  matches nothing — the nil result is then dereferenced, giving an access violation
  inside `delphicoreide*.bpl` with no hint as to the cause.
- `GetFrameworkType` must return exactly `'FMX'` or `'VCL'`. `'FireMonkey'` is
  accepted and silently stored as a third, meaningless framework, after which the
  IDE warns that your units are incompatible with the project.
- `IOTAModule.Save(ChangeName, ForceSave)` has no "prompt" parameter.
  `ForceSave = True` is what suppresses the *"Save changes to X?"* dialog.
- `IOTAThread.CallHeaders` and `GetCallPos` are **one-based**. Indexing from 0 trips
  an assertion inside the debug kernel (`item.src`, `DBKIMPL.CPP`) which raises a
  modal error dialog — which then blocks the bridge, so the visible symptom is a
  hang that points nowhere near the indexing.
- `IOTAEditActions` is implemented by the edit *buffer*, not by `IOTAEditor`, so
  casting `Module.CurrentEditor` to it can never succeed. Run and stepping go
  through `INTAServices.ActionList` instead, which needs no focused editor. The
  action names are undocumented and have changed between releases — use
  `listIdeActions` to discover them rather than guessing.
