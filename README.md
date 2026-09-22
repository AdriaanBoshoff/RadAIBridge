# RAD AI Bridge

Lets an AI coding agent (Claude Code, or anything else that speaks MCP) drive a
**running RAD Studio IDE**: read and write live editor buffers, manage project
files, build with structured error output, drive the debugger, and inspect or
edit the FMX/VCL form Designer's component tree.

Not a code generator that writes files and hopes. It talks to the IDE you
already have open, through the Open Tools API, so the agent sees exactly what
you see — the same buffers, the same project, the same debug session.

```
┌─────────────┐   stdio    ┌────────────┐   TCP/JSON   ┌──────────────────┐
│ Claude Code │ ─────────► │ MCP server │ ───────────► │ RadAiBridge.bpl  │
│  (or other) │            │  (Node.js) │   loopback   │ inside RAD Studio│
└─────────────┘            └────────────┘              └──────────────────┘
```

Two pieces:

- **`IdePlugin/`** — a Delphi Open Tools API package (`RadAiBridge.bpl`) that
  loads into RAD Studio and runs a small JSON-RPC server on a loopback TCP
  socket. No UI, no menu entry.
- **`McpServer/`** — a Node.js MCP server launched over stdio. It reads the
  plugin's published port and forwards MCP tool calls to it.

Developed and verified against **RAD Studio 13 (Delphi 37.0)** on Windows.

---

## Requirements

- RAD Studio / Delphi with the command-line compiler (`dcc32.exe`) — any
  edition that includes `designide`.
- Node.js 18+ (for the MCP server).
- Windows. The IDE host process is Win32, so the plugin is Win32 only. This has
  no bearing on what *your* projects target.

---

## 1. Build and install the IDE plugin

The plugin must be compiled for **Win32** — `bds.exe` is a 32-bit process, so
design-time packages must match it regardless of what platforms your own
projects target.

### Option A — the build script (recommended)

From a bash shell (Git Bash ships with RAD Studio-era Windows toolchains, or
use WSL/MSYS):

```bash
cd IdePlugin
./rebuild.sh
```

This compiles, shuts the IDE down, deploys the `.bpl`, restarts the IDE and
waits until the bridge reports itself up. Set `BDS_VER` if you are not on
37.0 (e.g. `BDS_VER=23.0 ./rebuild.sh`).

The script deliberately closes RAD Studio before copying. Writing over a `.bpl`
that a running IDE has mapped appears to succeed but leaves an image the next
IDE start silently fails to load — no error dialog, the package simply never
appears. That failure mode is very hard to recognise, so the script makes it
impossible.

### Option B — from inside the IDE

1. Open `IdePlugin/RadAiBridge.dproj`.
2. Set the target platform to **Windows 32-bit** and build.
3. Right-click the project → **Install**.

### Registering it manually

The package must be listed under:

```
HKCU\SOFTWARE\Embarcadero\BDS\<version>\Known Packages
```

as a string value whose *name* is the full path to `RadAiBridge.bpl` and whose
*data* is any description. `rebuild.sh` does not do this for you — install once
via the IDE (Option B), or add the value yourself.

### Confirming it loaded

On every start the plugin writes its port to:

```
%APPDATA%\RadAiBridge\bridge.json
```

If that file appears after RAD Studio starts, the bridge is live. If it does
not, the package did not load — check that the path in *Known Packages* points
at a `.bpl` that exists.

---

## 2. Build the MCP server

```bash
cd McpServer
npm install
npm run build
```

This produces `McpServer/dist/index.js`.

---

## 3. Point your agent at it

A project-level `.mcp.json` is included:

```json
{
  "mcpServers": {
    "rad-ai-bridge": {
      "command": "node",
      "args": ["./McpServer/dist/index.js"]
    }
  }
}
```

Use an absolute path in `args` if you want it available from any working
directory, or put the same block in your user-level config.

Start RAD Studio first, then your agent. With both running you get tools like
`getFormTree`, `applyEdit`, `compileProject`, `runProject`, `getCallStack` and
`addBreakpoint`.

---

## Tool reference

41 tools, grouped roughly as they appear in `McpServer/src/index.ts`:

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

## Developer tools

`IdePlugin/tools/` holds two scripts that make working on the bridge bearable:

**`call.js`** — drives the RPC socket directly, bypassing MCP entirely. An MCP
client usually cannot be made to reconnect on demand, so without this every
plugin change would need an agent restart just to exercise one tool.

```bash
node tools/call.js getProjectInfo
node tools/call.js addBreakpoint 'filePath=C:\src\MainFormU.pas' line=74
node tools/call.js getCallStack maxFrames=8
```

Parameters are `key=value`, parsed as JSON when that succeeds and kept as plain
strings otherwise — so Windows paths survive without backslash escaping.

**`dismiss-ide-modal.ps1`** — reports, and optionally clicks, a modal dialog
blocking the IDE:

```powershell
./tools/dismiss-ide-modal.ps1              # report what is showing
./tools/dismiss-ide-modal.ps1 -Button No   # click "No"
```

---

## Known limitations

- **Any modal dialog in the IDE blocks every bridge call.** Tool handlers run
  on the IDE main thread, so while a dialog is up, calls queue until it is
  dismissed. Calls fail after 120s with a message naming the likely cause
  rather than hanging forever. Common culprits: *"Source has been modified.
  Rebuild?"*, third-party wizards that prompt on component creation (CnPack's
  component-name dialog is a frequent one), and unsaved project groups.
  `dismiss-ide-modal.ps1` is the escape hatch. Routing work through a posted
  window message instead of `TThread.Synchronize` does **not** avoid this — a
  modal's own message loop does not dispatch the posted work.
- **One IDE instance at a time.** The discovery file holds a single port. A
  second instance overwrites it. (Shutdown is at least PID-checked, so an
  instance closing will not delete a newer instance's entry.)
- **`compileProject` shells out to `msbuild`** via `rsvars.bat` rather than
  using the IDE's internal message view, whose API is thinly documented. The
  result is clean structured errors at the cost of being slower than an
  in-process build. It runs off the main thread so the IDE stays responsive,
  and full `msbuild` output is returned only on request
  (`includeRawOutput: true`) or when a failure could not be parsed.
- **Designer tools are framework-agnostic** (FMX and VCL) — they go through
  `IDesigner` plus RTTI rather than anything framework-specific.
- `runToCursor` depends on the editor's current caret position, which the
  bridge does not set for you.

---

## Notes for anyone extending this

A few things cost real time to work out; they are documented in the source but
worth repeating:

- `IOTAProjectCreator.GetFileName` must return the **`.dpr`**, never the
  `.dproj`. The IDE resolves the project-type handler from that extension, and
  a `.dproj` matches nothing — the nil result is then dereferenced, giving an
  access violation inside `delphicoreide*.bpl` with no hint as to the cause.
- `GetFrameworkType` must return exactly `'FMX'` or `'VCL'`. `'FireMonkey'` is
  accepted and silently stored as a third, meaningless framework, after which
  the IDE warns that your units are incompatible with the project.
- `IOTAModule.Save(ChangeName, ForceSave)` has no "prompt" parameter.
  `ForceSave = True` is what suppresses the *"Save changes to X?"* dialog.
- `IOTAThread.CallHeaders` and `GetCallPos` are **one-based**. Indexing from 0
  trips an assertion inside the debug kernel (`item.src`, `DBKIMPL.CPP`) which
  raises a modal error dialog — which then blocks the bridge, so the visible
  symptom is a hang that points nowhere near the indexing.
- `IOTAEditActions` is implemented by the edit *buffer*, not by `IOTAEditor`,
  so casting `Module.CurrentEditor` to it can never succeed. Run and stepping
  go through `INTAServices.ActionList` instead, which needs no focused editor.
  The action names are undocumented and have changed between releases — use
  `listIdeActions` to discover them rather than guessing.
- A `.bpl` cannot hot-reload. Every plugin change needs a full IDE restart.
