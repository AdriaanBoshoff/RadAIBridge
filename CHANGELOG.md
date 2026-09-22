# Changelog

All notable changes to this project are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).
This project has not made a tagged release yet; everything below is on `main`.

## Unreleased

### Added

- **`captureScreenshot`** — returns a real PNG of the running program's window
  (`target: "app"`) or of the IDE itself (`target: "ide"`), as an image content
  block the model can actually see. Uses `PrintWindow` with
  `PW_RENDERFULLCONTENT`, so the window does not need to be focused or
  unobscured, and FMX/GPU-composited windows do not come back black.
  This is registered raw rather than marshalled onto the IDE main thread and
  makes no ToolsAPI call for `target: "ide"`, so it still answers while a modal
  dialog has the IDE blocked — which is the only way for an agent to find out
  *what* is blocking it.
- **`saveFile`** — force-saves one module (`filePath`) or every modified, rooted
  module. For when something outside the IDE, such as `git`, has to see edits
  that so far only exist in editor buffers.
- **`stepOut`** — maps to the IDE's `RunUntilReturnCommand`.
- **`listIdeActions`** — enumerates the IDE's action list with an optional
  `contains` filter. Built to discover real action names, since they are
  undocumented and all end in `Command`.
- `maxFrames` parameter on `getCallStack` (default 64).
- Windows-native **`install.ps1`** and **`uninstall.ps1`**, plus
  `IdePlugin/rebuild.ps1` for the development loop. No bash required.
- `CONNECTING.md` — per-client MCP configuration for Claude Code, Claude
  Desktop, Cursor, VS Code/Copilot, Cline/Roo, Windsurf, Continue and Zed.
- `skills/rad-ai-bridge/` — an agent skill covering modal avoidance, tool
  ordering and recovery, with a mapping to other agents' rule-file formats.
- `LICENSE` (MIT).

### Fixed

The five defects below were all found in one sitting, by using the bridge to
build a real FMX application with it rather than by exercising tools one at a
time. That turned out to be worth more than any amount of individual testing.

- **The RPC server died permanently on any exception.** The accept loop had no
  guard, so one exception unwound `Execute` and killed the thread. The IDE
  carried on running with no listener: every later call got `ECONNREFUSED`,
  with no error and no dialog, and the only recovery was restarting the IDE.
- **The server served one client at a time.** `HandleClient` was called inline
  from the accept loop, so a blocked call held the whole server. This defeated
  the point of registering `captureScreenshot` raw — an agent whose call was
  stuck could not screenshot the IDE to find out why, because the stuck call
  still owned the connection. Each client now gets its own thread.
- **`compileProject` reported `success: true` on a failed build.** Its parser
  only matched msbuild's `[dcc32 Error]` shape, but this toolchain emits
  `MainForm.pas(141): error E2003: ...`. Nothing matched, and `success` was
  derived from that empty count. Both formats are matched now, duplicates
  (msbuild prints each diagnostic twice) are collapsed, hints are no longer
  passed off as warnings, and the verdict comes from msbuild's own
  `Build succeeded`/`Build FAILED` rather than from what the parser recognised.
- **`applyEdit` could not match anything spanning more than one line.** Editor
  buffers are CRLF; callers send LF. Matching is now done on normalised text,
  and the buffer's own convention is restored before writing.
- **`addComponent` did not add the component's unit to the form's `uses`
  clause.** A form built entirely through the Designer tools would not compile
  — `TButton` and `TLabel` were undeclared — until `addUsesUnit` was called by
  hand. It now does what the IDE does when a component comes off the palette,
  and reports `declaringUnit` and `unitAddedToUses`.

- **IDE shutdown deadlock.** The listener thread parked in `accept()` never
  returned, so `Terminate`/`WaitFor` hung and left a zombie `bds.exe` holding
  the port. The listening socket is now closed from an overridden
  `TThread.TerminatedSet`.
- **`ECONNRESET` after every successful call.** Closing the client socket
  abruptly sent an RST that the client saw instead of the reply already on the
  wire. Now `shutdown(SD_SEND)` followed by a bounded drain.
- **`getCallStack` crashed the debug kernel** (`Assertion failure: "item.src",
  DBKIMPL.CPP`) and raised a modal that then blocked the whole bridge.
  `IOTAThread.CallHeaders` and `GetCallPos` are **one-based**; the loop was
  zero-based.
- **`runProject` and the stepping tools did nothing.** They used an interface
  that the edit buffer, not the editor, implements, and then guessed action
  names. They now execute the IDE's own actions by their real names
  (`RunRunCommand`, `RunStepOverCommand`, `RunTraceIntoCommand`,
  `RunUntilReturnCommand`, `RunGotoCursorCommand`, `RunResetCommand`).
- **Discovery file deleted by the wrong process.** A second IDE instance
  shutting down removed a live instance's `bridge.json`. The delete is now
  PID-checked.
- **`captureScreenshot` found no window**, twice. `IOTAProcess.ProcessId` is the
  debugger's internal id, not the OS PID — `OSProcessId` is. And filtering out
  owned windows rejected the real main form, because VCL and FMX both give the
  application a hidden owner window.
- Corrected a comment in `RadAiBridge.MainThread` that claimed posting a window
  message survives a modal dialog. Measured: it does not.

### Notes

- Overwriting a deployed `.bpl` while an IDE has it mapped appears to succeed
  but leaves an image the next IDE start silently refuses to load, with no
  error. Both `install.ps1` and `rebuild.ps1` now close the IDE before copying.
