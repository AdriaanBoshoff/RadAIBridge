---
name: rad-ai-bridge
description: Drive a running RAD Studio IDE through the RAD AI Bridge MCP tools - edit live buffers, build, debug, and edit FMX/VCL forms. Use whenever working on a Delphi/RAD Studio project with the rad-ai-bridge server connected.
---

# RAD AI Bridge

You are driving a **live, running RAD Studio IDE**, not a folder of files. The
user is watching. Every change you make appears in their editor and Designer
immediately.

## When to use this skill

Any time the `rad-ai-bridge` MCP tools are available and the work involves a
Delphi/RAD Studio project: editing units, laying out forms, building, or
debugging.

---

## The one rule that matters most

**Any modal dialog in the IDE blocks every bridge call.** Tool handlers run on
the IDE's main thread. While a dialog waits for an answer, every call you make
queues behind it and eventually fails after 120 seconds.

If a call hangs, it is almost never a deadlock in the bridge. It is a dialog
sitting on the user's screen. **Do not theorise, and do not retry in a loop.**

**Look at it first.** `captureScreenshot` with `target: "ide"` is the one tool
that keeps working while a modal is up — it is registered raw instead of being
marshalled onto the main thread, and it makes no ToolsAPI call, so a blocked
main thread does not affect it. Call it and *read the dialog* before doing
anything else:

```
captureScreenshot { "target": "ide" }
```

(`target: "app"` needs one ToolsAPI lookup to find the debugged process, so that
variant will stall behind the modal too. During a hang, use `"ide"`.)

Then tell the user what is showing, or if you have shell access, act on it:

```powershell
.\IdePlugin\tools\dismiss-ide-modal.ps1              # report what is showing
.\IdePlugin\tools\dismiss-ide-modal.ps1 -Button No   # click a specific button
```

Never blind-click a dialog you have not read. "Never" and "Don't ask again"
buttons change the user's IDE settings permanently.

---

## Avoiding modals in the first place

These are the dialogs that actually come up, and how to not trigger them.

### "Source has been modified. Rebuild?"
Triggered by running or stepping after source changed since the last build.

**Do:** call `compileProject` after editing and before `runProject` or any
stepping tool. Never edit source in the middle of a live debug session — stop
the session, edit, rebuild, start again.

### Component-name prompts from third-party wizards
CnPack's "component name" dialog fires on **every** `addComponent` call. Other
IDE add-ons do similar things.

**Do:** if `addComponent` hangs on a project where add-ons are installed, tell
the user to turn off the wizard's naming prompt. This is a one-time setting, and
without it, form building is unusable.

### "Save changes to X?"
Triggered by saving a module that has never been written to disk.

**Do:** nothing special — `compileProject` force-saves correctly. But do not
create modules you never intend to save, and be aware an unsaved *project group*
pops a "Save As" that blocks everything.

### Framework-mismatch warnings
"Unit X is incompatible with the FireMonkey framework used by the project."

**Do:** never pass `framework: "FireMonkey"`. Only `"FMX"` or `"VCL"` are valid.
Better: omit the parameter on `createForm` entirely and let it inherit the
project's framework.

---

## Start every session by orienting yourself

Do not assume. One call tells you the project, framework, platform, config and
file list:

```
getProjectInfo
```

If it returns "No active project", ask the user to open one, or use
`openProject` with a `.dproj` path. `listOpenFiles` shows what is open in the
editor.

Check `frameworkType` before you touch forms — FMX and VCL have entirely
different component names (`TButton` exists in both; `TEdit`, layouts and
anchors do not behave the same).

---

## Editing source

**The editor buffer is the truth, not the file on disk.** The user may have
unsaved changes. `getEditorContent` reads the live buffer.

- Prefer **`applyEdit`** (targeted replacement) over `setEditorContent` (whole
  file). Whole-file writes discard the user's cursor position, fold state, and
  any concurrent edit they just made.
- Use `getEditorLines` when you only need a range — cheaper than the whole file.
- After adding a unit reference, use **`addUsesUnit`** rather than hand-editing
  the `uses` clause. It puts the entry in the right clause and avoids duplicates.
- **`saveFile`** flushes buffers to disk — one module with `filePath`, or every
  rooted, modified module when called with no arguments. It force-saves, so it
  does not raise "Save changes to X?".

You rarely need `saveFile` before building, because `compileProject` saves
first. Reach for it when something *outside* the IDE has to see your edits: git,
a linter, a build script, or the user opening the file in another editor. That
is a real trap — an agent that edits buffers and then runs `git diff` sees
nothing and concludes its edits vanished.

---

## Working with forms and the Designer

**Read the tree before you change it:**

```
getFormTree
```

This gives the component hierarchy with names and types. `getComponentProperties`
gives the properties of one component.

**Batch your property changes.** Use `setComponentProperties` (plural) with all
properties for a component in one call, not a chain of `setComponentProperty`
calls. It is dramatically faster, and each round trip is another chance for an
add-on wizard to interrupt you.

Typical order for building a form:

1. `addComponent` — create it, with a parent name for nesting
2. `setComponentProperties` — position, size, alignment, caption, all at once
3. `setComponentEvent` — wire the handler, which creates the method stub
4. Fill in the handler body with `applyEdit`

Set the parent when adding, rather than reparenting afterwards. For FMX, prefer
`Align` and layout containers over hard-coded pixel positions.

---

## Building

```
compileProject
```

Returns a one-line `summary` plus structured `errors` and `warnings` arrays with
file, line, code and message. That is all you normally need.

- It saves all modified modules first, so you do not need to save separately.
- It runs off the IDE main thread, so the IDE stays responsive.
- **Do not pass `includeRawOutput: true` unless you are debugging the build
  itself.** Raw msbuild output is thousands of lines of library search paths —
  roughly 8,000 tokens of noise per build.
- Fix the **first** error and rebuild. Later errors in Delphi are very often
  cascades from the first one.

---

## Look at what you built

"It compiles and it runs" is a low bar for UI work. `getFormTree` tells you a
control exists and where it claims to be; it does not tell you the caption is
clipped, two panels overlap, the text is unreadable on that background, or the
form came up blank because the constructor raised.

```
runProject
captureScreenshot { "target": "app" }
```

Returns a real PNG of the running program's window, which you can actually see.
Use it:

- after any layout or styling change, before telling the user it is done;
- when a user says "it looks wrong" — look, rather than asking them to describe
  it;
- to confirm the app got past startup at all.

Notes that save you a round trip:

- Give the program a moment after `runProject`. If the main form has not been
  shown yet, the call says so — wait briefly and repeat rather than concluding
  the app failed.
- It uses `PrintWindow`, so the window does **not** need to be focused or
  unobscured. Do not ask the user to bring it to the front.
- `windowTitle` narrows the target when the app owns several windows.
- If the program is stopped at a breakpoint before its form is shown, there is
  nothing to capture yet. That is expected, not an error in your setup.

Do not screenshot after every trivial edit — it is a large image each time.
Screenshot at the point where you would otherwise claim the UI is correct.

---

## Debugging

Order matters:

```
compileProject          →  build first, or you get a "Rebuild?" modal
addBreakpoint           →  filePath + line
runProject              →  starts the session and returns IMMEDIATELY
                           (it does not wait for the breakpoint to hit)
getCallStack            →  once stopped
evaluateExpression      →  once stopped
stepOver / stepInto / stepOut / runToCursor
terminateProcess        →  clean up when done
```

**Breakpoint lines must be executable.** A `var` declaration, a blank line, or a
bare `begin` will not hit. Read the source first and pick a statement.

**`runProject` and the stepping tools return as soon as the IDE accepts the
command**, not when execution stops. Wait a few seconds before calling
`getCallStack`, and expect an error saying the thread is not stopped if you are
too early — that error is informative, not a failure.

**`getCallStack` and `evaluateExpression` require a stopped thread.** They refuse
otherwise rather than returning nonsense. Use `maxFrames` to keep the payload
small; `totalFrames` still reports the true depth.

Values read before a line executes are uninitialised garbage — that is correct
behaviour, not a bug. Check *where* you are stopped before interpreting a value.

Always `terminateProcess` (and usually `removeAllBreakpoints`) when finished.
Leaving a debug session running blocks the next build and confuses the user.

---

## Creating projects and forms

- `createProject` — `framework` must be `"FMX"`, `"VCL"`, or omitted. Give it the
  project path; it handles the `.dpr`/`.dproj` pair itself.
- `createForm` — omit `framework` so it inherits from the project. Passing the
  wrong one produces a form the project warns about and may not compile.
- `createUnit` — for non-form units.

After creating, call `getProjectInfo` again to confirm the file list is what you
expect before building on top of it.

---

## When something goes wrong

**A call hangs or times out after 120s**
A modal is blocking the IDE. See the top of this document. Do not retry blindly.

**"No active project"**
Nothing is open. `openProject`, or ask the user.

**Tools error but the IDE looks fine**
Check RAD Studio is actually running, and that
`%APPDATA%\RadAiBridge\bridge.json` exists. Without that file the MCP server
cannot find the IDE.

**A debugger tool reports the thread is not stopped**
You are running, not paused. Wait for a breakpoint, or the process already
terminated.

**You need an IDE command that has no tool**
`listIdeActions` with a `contains` filter lists the IDE's own actions with their
captions and enabled state. Useful for discovering what is available; the names
are undocumented and change between releases, so never guess them.

---

## Working style

- **Report honestly.** If a build fails, say so and show the errors. Do not
  describe a form as built until `compileProject` succeeds.
- **The user is watching their IDE.** Sweeping unrequested changes to open files
  are disruptive in a way they are not in a normal repo.
- **Prefer few, well-formed calls.** Every round trip is a chance for an IDE
  dialog to interrupt. Batch properties, read trees before editing them, and do
  not poll.
