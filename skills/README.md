# Agent skills

`rad-ai-bridge/SKILL.md` teaches an AI agent how to use these tools well: which
tool to reach for, what order to do things in, and — most importantly — how to
avoid the IDE modal dialogs that block every bridge call.

It is worth installing. Without it an agent will still function, but it will
tend to make many small calls where one batched call would do, will try to read
a call stack before the program has stopped, and will misread a modal-blocked
call as a crash.

## Claude Code

Copy the folder into your skills directory.

Just this project:

```powershell
New-Item -ItemType Directory -Force .claude\skills | Out-Null
Copy-Item -Recurse -Force .\skills\rad-ai-bridge .claude\skills\
```

Every project:

```powershell
Copy-Item -Recurse -Force .\skills\rad-ai-bridge $env:USERPROFILE\.claude\skills\
```

Claude picks it up on the next session and invokes it automatically when the
work involves RAD Studio.

## Other agents

`SKILL.md` is plain Markdown with a small YAML header — there is nothing
Claude-specific in the body. For agents that support custom instruction or rule
files, paste the body into whatever that tool uses:

| Tool | Where |
| --- | --- |
| Cursor | `.cursor/rules/rad-ai-bridge.mdc` |
| Cline / Roo Code | `.clinerules/` |
| Windsurf | `.windsurfrules` |
| VS Code / Copilot | `.github/copilot-instructions.md` |
| Continue | a rules block in `config.yaml` |
| Anything else | its system-prompt or project-instructions field |

Strip the `---` header block if the target does not understand YAML frontmatter.
