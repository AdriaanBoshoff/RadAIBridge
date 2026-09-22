#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { BridgeClient } from "./bridgeClient.js";

const bridge = new BridgeClient();

const server = new McpServer({
  name: "rad-ai-bridge",
  version: "1.0.0",
});

function toResult(value: unknown) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text" as const, text }] };
}

function tool(
  name: string,
  description: string,
  shape: Record<string, z.ZodTypeAny>,
  rpcMethod: string = name
) {
  server.registerTool(
    name,
    { description, inputSchema: shape },
    async (args: Record<string, unknown>) => {
      try {
        const result = await bridge.call(rpcMethod, args);
        return toResult(result);
      } catch (err) {
        return {
          content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }],
          isError: true,
        };
      }
    }
  );
}

// --- Files & editor buffers -------------------------------------------------

tool("listOpenFiles", "List every file currently open in the RAD Studio IDE.", {});

tool(
  "getEditorContent",
  "Get the full text of a file. Reads the live IDE editor buffer if the file is open (including unsaved changes), otherwise reads from disk.",
  { filePath: z.string().describe("Absolute path to the file") }
);

tool(
  "getEditorLines",
  "Get a range of lines from a file (1-based, inclusive start). Prefer this over getEditorContent for large files.",
  {
    filePath: z.string(),
    startLine: z.number().int().min(1).default(1),
    lineCount: z.number().int().min(1).default(200),
  }
);

tool(
  "setEditorContent",
  "Replace the entire content of a file. Prefer applyEdit for small changes; use this only for full rewrites.",
  { filePath: z.string(), content: z.string() }
);

tool(
  "applyEdit",
  "Replace an exact, unique block of text in a file with new text (find-and-replace on an exact match). " +
    "oldContent must match the file's current content exactly, including whitespace, and must be unique in the file.",
  { filePath: z.string(), oldContent: z.string(), newContent: z.string() }
);

tool(
  "openFile",
  "Open a file in the IDE editor.",
  { filePath: z.string(), show: z.boolean().default(true).describe("Bring the file to front in the editor") }
);

tool(
  "saveFile",
  "Save a file's editor buffer to disk. Omit filePath to save every open module. Edits otherwise only reach disk as a side effect of compileProject, and an unsaved buffer is one of the things that later pops a blocking modal.",
  { filePath: z.string().optional().describe("Absolute path; omit to save everything") }
);

// --- Project structure -------------------------------------------------------

tool(
  "getProjectInfo",
  "Get info about the active project (or a specific open project): file name, project type, and contained files.",
  { projectFile: z.string().optional().describe("Path to a specific open .dproj; omit for the active project") }
);

tool(
  "addFileToProject",
  "Add an existing file on disk to the active project.",
  {
    filePath: z.string(),
    isUnitOrForm: z.boolean().default(true).describe("True for a Pascal unit/form file, false for other file types"),
  }
);

tool("removeFileFromProject", "Remove a file from the active project (does not delete it from disk).", {
  filePath: z.string(),
});

tool("openProject", "Open a project (.dproj/.dpr) or project group (.groupproj) in the IDE.", {
  filePath: z.string(),
});

tool(
  "setProjectPlatform",
  "Change the active project's target platform and/or build configuration — the equivalent of picking them in the " +
    "Project Manager's target combo. Call getProjectInfo first to see supportedPlatforms.",
  {
    platform: z.string().optional().describe("e.g. Win32, Win64, Android64, iOSDevice64"),
    config: z.string().optional().describe("e.g. Debug, Release"),
  }
);

tool(
  "listBuildConfigurations",
  "List the active project's build configurations (Base/Debug/Release and any custom ones) and the platforms each covers.",
  {}
);

tool(
  "listProjectOptions",
  "List the option names and values set on one build configuration. Use this to discover option names — they are not " +
    "otherwise guessable. Omit config/platform for the active configuration's cross-platform values.",
  {
    config: z.string().optional().describe("Configuration name, e.g. Debug or Release; defaults to the active one"),
    platform: z.string().optional().describe("Platform, e.g. Android64, for that platform's overrides"),
  }
);

tool(
  "getProjectOption",
  "Read one project option, resolving inheritance from parent configurations so you get the value a build would use. " +
    "Project settings are per build configuration and per platform, so pass config/platform to target a specific one.",
  {
    optionName: z.string().describe("e.g. DCC_Optimize, VerInfo_Keys, Icon_MainIcon"),
    config: z.string().optional(),
    platform: z.string().optional(),
  }
);

tool(
  "setProjectOption",
  "Set one project option on a build configuration. Omit config/platform to set it on the active configuration.",
  {
    optionName: z.string(),
    value: z.string(),
    config: z.string().optional(),
    platform: z.string().optional(),
  }
);

// --- Creating modules ---------------------------------------------------------

tool(
  "createUnit",
  "Create a new plain Pascal unit and add it to the active project. The unit gets a live editor buffer and appears " +
    "in the Project Manager. Defaults to the project's own directory.",
  {
    unitName: z.string().describe("Unit name without extension, e.g. NoteStorage"),
    body: z.string().optional().describe("Optional code placed in the implementation section"),
    filePath: z.string().optional().describe("Full .pas path; defaults to <project dir>\\<unitName>.pas"),
    show: z.boolean().default(true).describe("Open the unit in the editor"),
  }
);

tool(
  "createForm",
  "Create a new form (unit + designer + .fmx/.dfm) and add it to the active project. Use framework 'FMX' for " +
    "FireMonkey or 'VCL' for Windows-only. After this, the new form becomes the one the designer tools act on.",
  {
    unitName: z.string().describe("Unit name without extension, e.g. NoteEditUnit"),
    formName: z.string().optional().describe("Form identifier; defaults to <unitName>Form"),
    framework: z
      .enum(["FMX", "VCL"])
      .optional()
      .describe("Defaults to the active project's own framework, which is almost always what you want"),
    filePath: z.string().optional().describe("Full .pas path; defaults to <project dir>\\<unitName>.pas"),
    show: z.boolean().default(true),
  }
);

tool(
  "createProject",
  "Create a new Delphi project and add it to the current project group, leaving whatever is already open alone. " +
    "The project starts empty — add forms and units with createForm/createUnit afterwards.",
  {
    filePath: z
      .string()
      .describe("Absolute path for the project, e.g. C:\\Work\\MyApp\\MyApp.dproj. The directory is created if needed."),
    framework: z
      .enum(["FMX", "VCL", "None"])
      .default("FMX")
      .describe("FMX for cross-platform FireMonkey, VCL for Windows-only, None for a non-visual project"),
    projectType: z.enum(["Application", "Console"]).default("Application"),
    platforms: z
      .array(z.string())
      .optional()
      .describe(
        "Target platforms. Defaults to Win32/Win64/Android/Android64/iOSDevice64 for FMX, Win32/Win64 otherwise."
      ),
    preferredPlatform: z.string().default("Win32").describe("Platform the project is active on after creation"),
  }
);

// --- Source editing -----------------------------------------------------------

tool(
  "addUsesUnit",
  "Add one or more units to a unit's uses clause, creating the clause if the section does not have one. " +
    "Units already present are left alone. Comments and string literals are ignored, so it will not be fooled " +
    "by a unit name mentioned in a comment.",
  {
    filePath: z.string().optional().describe("Full path of the .pas file; defaults to the file open in the editor"),
    unitName: z.string().optional().describe("Single unit to add, e.g. System.IOUtils"),
    unitNames: z.array(z.string()).optional().describe("Several units to add in one pass"),
    section: z
      .enum(["interface", "implementation"])
      .default("interface")
      .describe("Put implementation-only dependencies in 'implementation' to keep the interface uses clause small"),
  }
);

// --- Build --------------------------------------------------------------------

tool(
  "compileProject",
  "Build the active project via the command-line toolchain (rsvars + msbuild), saving all open files first. " +
    "Returns a one-line summary plus structured errors/warnings (file, line, code, message). Raw msbuild output " +
    "is omitted by default because it is thousands of lines of library search paths; it is returned automatically " +
    "if the build fails in a way that could not be parsed.",
  {
    config: z.string().default("Debug").describe("Build configuration, e.g. Debug or Release"),
    platform: z.string().default("Win32").describe("Target platform, e.g. Win32, Win64, Android, iOSDevice64"),
    includeRawOutput: z
      .boolean()
      .default(false)
      .describe("Return the full msbuild log. Very large — only for diagnosing the build system itself."),
  }
);

// --- UI Designer (works for both FMX and VCL forms) ----------------------------

tool(
  "getFormTree",
  "Get the component tree of the form/frame currently open in the Designer, nested by visual parent. " +
    "By default only layout-relevant properties are returned; pass allProperties to dump everything (verbose). " +
    "Works for both FMX and VCL.",
  {
    allProperties: z
      .boolean()
      .default(false)
      .describe("Include every published property of every component. Very large output — prefer getComponentProperties."),
  }
);

tool("getComponentProperties", "Get all published properties of a named component on the currently open form.", {
  componentName: z.string(),
});

tool(
  "setComponentProperty",
  "Set a published property on a named component on the currently open form. propertyName may be a dotted path " +
    "(Position.X, Size.Width, TextSettings.Font.Size). Sets take a literal like '[akLeft,akBottom]', colours take " +
    "a name like 'claRed' or a number, booleans take 'true'/'false', enums take the member name like 'Client'.",
  { componentName: z.string(), propertyName: z.string(), value: z.string() }
);

tool(
  "setComponentProperties",
  "Set many properties in one call — strongly preferred over repeated setComponentProperty when laying out a form. " +
    "Keys are 'ComponentName.PropertyPath' (e.g. 'AddBtn.Size.Width'), or plain property paths if componentName is given. " +
    "Values use the same syntax as setComponentProperty. Every assignment is attempted; the result reports how many " +
    "applied and lists each failure with its reason.",
  {
    properties: z.record(z.string()).describe("Map of property path to value"),
    componentName: z
      .string()
      .optional()
      .describe("If set, keys are property paths on this one component instead of 'Component.Path'"),
  }
);

tool(
  "selectComponent",
  "Select one or more components in the Designer, so the Object Inspector shows them and the user can see what " +
    "you are talking about. Pass an empty list to select the form itself. Purely a UI action — it changes nothing.",
  {
    componentNames: z.array(z.string()).describe("Names of components to select; empty selects the form"),
  }
);

tool(
  "addComponent",
  "Add a new component to the currently open form. The component class must already be known to the IDE " +
    "(already used elsewhere in the project, or its unit is in the form's uses clause).",
  {
    className: z.string().describe("e.g. TButton, TLabel, TEdit, TLayout"),
    name: z
      .string()
      .optional()
      .describe(
        "Component name, e.g. SaveBtn. Strongly recommended: it is how every other tool addresses the component, " +
          "it shapes generated event handler names, and it avoids IDE add-ins prompting to rename default-named components on save."
      ),
    parentName: z.string().optional().describe("Name of the parent component; omit to add directly to the form"),
    left: z.number().int().default(0),
    top: z.number().int().default(0),
    width: z.number().int().default(100),
    height: z.number().int().default(25),
  }
);

tool(
  "setComponentEvent",
  "Wire an event (e.g. OnClick) on a named component to a method on the form. If the method doesn't exist yet, " +
    "it is created (skeleton procedure added to the form's unit), just like typing a new name into the Object " +
    "Inspector's Events tab. If it already exists with a matching signature, it's simply bound.",
  { componentName: z.string(), eventName: z.string().describe("e.g. OnClick"), methodName: z.string().describe("e.g. AddBtnClick") }
);

tool("deleteComponent", "Delete a named component from the currently open form.", { componentName: z.string() });

// --- Visual feedback --------------------------------------------------------

// Registered directly rather than through tool(), because the result has to be
// an image content block. Handed back as text, a base64 PNG is just a wall of
// characters the model cannot see - which defeats the entire point.
server.registerTool(
  "captureScreenshot",
  {
    description:
      "Take a screenshot and SEE it. target 'app' captures the program currently running under the debugger — use this to verify a UI actually looks right (layout, overlap, clipped text, blank forms) rather than assuming it does from the component tree. target 'ide' captures the RAD Studio window itself, which is the way to read a modal dialog that is blocking other calls. Call runProject first for 'app', and allow a moment for the main form to appear.",
    inputSchema: {
      target: z
        .enum(["app", "ide"])
        .optional()
        .describe("'app' (default) = the running program; 'ide' = RAD Studio itself"),
      windowTitle: z
        .string()
        .optional()
        .describe("Case-insensitive substring to pick a specific window when the process has several"),
    },
  },
  async (args: Record<string, unknown>) => {
    try {
      const shot = (await bridge.call("captureScreenshot", args)) as {
        base64: string;
        width: number;
        height: number;
        windowTitle: string;
      };
      return {
        content: [
          {
            type: "text" as const,
            text: `"${shot.windowTitle}" — ${shot.width}x${shot.height}`,
          },
          { type: "image" as const, data: shot.base64, mimeType: "image/png" },
        ],
      };
    } catch (err) {
      return {
        content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- Debugger -------------------------------------------------------------------

tool("runProject", "Run (or continue) the active project, starting a debug session if not already running.", {});
tool("stepOver", "Debugger: step over the current source line.", {});
tool("stepInto", "Debugger: step into the current source line.", {});
tool("stepOut", "Debugger: run until the current function returns, stopping in the caller.", {});
tool("runToCursor", "Debugger: run until the cursor's current position in the editor is reached.", {});
tool("terminateProcess", "Stop/terminate the running debug session.", {});

tool(
  "listIdeActions",
  "Diagnostic: list the IDE's registered actions (name, caption, enabled). Use 'contains' to filter, e.g. 'run' or 'step'. Useful for finding the action name behind a menu command.",
  { contains: z.string().optional().describe("Case-insensitive substring matched against action name and caption") }
);

tool("addBreakpoint", "Add a source breakpoint at a file and line.", {
  filePath: z.string(),
  line: z.number().int(),
});

tool("removeBreakpoint", "Remove the source breakpoint at a file and line.", {
  filePath: z.string(),
  line: z.number().int(),
});

tool("removeAllBreakpoints", "Remove every breakpoint in the project.", {});
tool("listBreakpoints", "List all current breakpoints.", {});

tool(
  "getCallStack",
  "Get the current call stack of the debugged process (only valid while stopped at a breakpoint/step). Each frame carries its source file and line where one is known.",
  { maxFrames: z.number().int().optional().describe("Cap the number of frames returned (default 64); totalFrames reports the true depth") }
);

tool(
  "evaluateExpression",
  "Evaluate an expression in the context of the currently stopped debug thread (only valid while stopped).",
  { expression: z.string() }
);

// --- Entry point ------------------------------------------------------------

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Fatal error starting rad-ai-bridge MCP server:", err);
  process.exit(1);
});
