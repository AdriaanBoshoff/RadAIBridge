unit RadAiBridge.Tools.Build;

{ Builds via the command-line toolchain (rsvars + msbuild) rather than poking
  at the IDE's internal message-view interfaces, which are thin on stable
  public documentation. This also gives clean, parseable dcc32/dcc64 output. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.RegularExpressions,
  System.IOUtils,
  Winapi.Windows, ToolsAPI, RadAiBridge.Ide.Utils, RadAiBridge.MainThread;

procedure RegisterBuildTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

function GetBdsRoot: string;
var
  ExeDir: string;
  Buf: array[0..MAX_PATH] of Char;
begin
  Result := GetEnvironmentVariable('BDS');
  if Result <> '' then
    Exit;
  // Fallback: bds.exe lives in <BDS>\bin, and this package is loaded inside it.
  FillChar(Buf, SizeOf(Buf), 0);
  GetModuleFileName(0, Buf, MAX_PATH);
  ExeDir := ExtractFileDir(Buf);
  Result := ExtractFileDir(ExeDir);
end;

{ The build is a tree - cmd.exe runs rsvars then msbuild, which runs dcc32 - so
  everything here is about not leaking or hanging on that tree:

  - The process goes into a job object with KILL_ON_JOB_CLOSE, so closing the
    job takes the whole tree down. Terminating cmd.exe alone leaves msbuild and
    dcc32 running, which is how stalled builds left orphans behind.
  - Output is drained with PeekNamedPipe rather than a blocking ReadFile. A
    grandchild holding the write handle open means the pipe never reaches EOF,
    and a blocking read then waits forever - past the timeout that was supposed
    to bound this. Polling lets the deadline actually apply. }
function RunProcessCaptureOutput(const CommandLine, WorkDir: string; TimeoutMs: Cardinal): string;
var
  SecurityAttr: TSecurityAttributes;
  ReadPipe, WritePipe, Job: THandle;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  JobLimits: TJobObjectExtendedLimitInformation;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead, Available: DWORD;
  Output: TBytesStream;
  CmdLineVar: string;
  Note: AnsiString;
  Deadline: UInt64;
  Exited, TimedOut: Boolean;
begin
  Output := TBytesStream.Create;
  Job := 0;
  try
    FillChar(SecurityAttr, SizeOf(SecurityAttr), 0);
    SecurityAttr.nLength := SizeOf(SecurityAttr);
    SecurityAttr.bInheritHandle := True;

    if not CreatePipe(ReadPipe, WritePipe, @SecurityAttr, 0) then
      raise Exception.Create('Failed to create output pipe');
    try
      SetHandleInformation(ReadPipe, HANDLE_FLAG_INHERIT, 0);

      Job := CreateJobObject(nil, nil);
      if Job <> 0 then
      begin
        FillChar(JobLimits, SizeOf(JobLimits), 0);
        JobLimits.BasicLimitInformation.LimitFlags :=
          JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(Job, JobObjectExtendedLimitInformation,
          @JobLimits, SizeOf(JobLimits));
      end;

      FillChar(StartupInfo, SizeOf(StartupInfo), 0);
      StartupInfo.cb := SizeOf(StartupInfo);
      StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
      StartupInfo.wShowWindow := SW_HIDE;
      StartupInfo.hStdOutput := WritePipe;
      StartupInfo.hStdError := WritePipe;
      StartupInfo.hStdInput := 0;

      CmdLineVar := CommandLine;
      UniqueString(CmdLineVar);

      { Suspended so the job assignment cannot race the first child spawn. }
      if not CreateProcess(nil, PChar(CmdLineVar), nil, nil, True,
        CREATE_NO_WINDOW or CREATE_SUSPENDED, nil, PChar(WorkDir),
        StartupInfo, ProcessInfo) then
        raise Exception.CreateFmt('Failed to launch build process (error %d)', [GetLastError]);
      try
        if Job <> 0 then
          AssignProcessToJobObject(Job, ProcessInfo.hProcess);
        ResumeThread(ProcessInfo.hThread);

        CloseHandle(WritePipe);
        WritePipe := 0;

        Deadline := GetTickCount64 + TimeoutMs;
        TimedOut := False;
        repeat
          Exited := WaitForSingleObject(ProcessInfo.hProcess, 0) = WAIT_OBJECT_0;

          Available := 0;
          if not PeekNamedPipe(ReadPipe, nil, 0, nil, @Available, nil) then
            Break; { write end fully closed and drained }

          if Available > 0 then
          begin
            if Available > SizeOf(Buffer) then
              Available := SizeOf(Buffer);
            if not ReadFile(ReadPipe, Buffer, Available, BytesRead, nil) or (BytesRead = 0) then
              Break;
            Output.Write(Buffer, BytesRead);
          end
          else
          begin
            { Nothing buffered and the process is gone: all output is in hand. }
            if Exited then
              Break;
            if GetTickCount64 > Deadline then
            begin
              TimedOut := True;
              Break;
            end;
            Sleep(25);
          end;
        until False;

        if TimedOut then
        begin
          Note := AnsiString(Format(
            #13#10'[RadAiBridge] Build timed out after %d ms and was terminated.'#13#10,
            [TimeoutMs]));
          Output.Write(PAnsiChar(Note)^, Length(Note));
        end;
      finally
        CloseHandle(ProcessInfo.hThread);
        CloseHandle(ProcessInfo.hProcess);
      end;
    finally
      if WritePipe <> 0 then
        CloseHandle(WritePipe);
      CloseHandle(ReadPipe);
    end;
    Result := TEncoding.ANSI.GetString(Output.Bytes, 0, Output.Size);
  finally
    { Closing the job kills anything still running in it. }
    if Job <> 0 then
      CloseHandle(Job);
    Output.Free;
  end;
end;

procedure SaveAllModifiedModules;
var
  MS: IOTAModuleServices;
  Module: IOTAModule;
  Group: IOTAProjectGroup;
  i: Integer;
begin
  MS := ModuleServices;
  if MS = nil then
    Exit;
  for i := 0 to MS.ModuleCount - 1 do
  begin
    Module := MS.Modules[i];
    { A project group is IDE bookkeeping, not build input, and an unsaved one
      makes Save pop a modal "Save As" that blocks the build indefinitely.
      Same for any module never written to disk: msbuild builds the .dproj, so
      skipping beats inventing a filename on the user's behalf. }
    if Supports(Module, IOTAProjectGroup, Group) then
      Continue;
    if not TPath.IsPathRooted(Module.FileName) then
      Continue;
    { Save(ChangeName, ForceSave). ForceSave=True is what suppresses the
      "Save changes to X?" confirmation - without it a module that has never
      been written to disk pops a modal and hangs the build. }
    Module.Save(False, True);
  end;
end;

{ msbuild reports compiler diagnostics in more than one shape, and which one
  you get depends on the toolchain version:

    [dcc32 Error] MainForm.pas(141): E2003 Undeclared identifier: 'X'
    MainForm.pas(141): error E2003: Undeclared identifier: 'X' [C:\...\App.dproj]

  Only the first was handled, so on a toolchain that emits the second the
  errors array came back empty - and because 'success' was derived from that
  count, a failed build was reported as a successful one. Both are matched
  now, and the verdict no longer depends on this function recognising
  anything (see BuildReportedSuccess). }
function ParseBuildOutput(const Output: string; out Errors, Warnings: TJSONArray): Integer;
const
  { file(line): severity CODE: message [project] - the trailing project path
    is msbuild's, not the compiler's, so it is dropped. }
  PlainPattern =
    '^\s*(.+?)\((\d+)(?:,\d+)?\):\s*(?:Hint\s+)?(error|warning|fatal error|hint)\s+' +
    '([A-Za-z]\d+):\s*(.*?)\s*(?:\[[^\]]*\])?$';
  BracketPattern =
    '\[dcc\w*\s+(Error|Warning|Fatal Error|Hint)\]\s+(.+?)\((\d+)\):\s*(\S+)\s+(.*)';
var
  Line, Key, FileName, Code, Message: string;
  Lines: TArray<string>;
  Match: TMatch;
  Entry: TJSONObject;
  LineNum: Integer;
  Seen: TStringList;
begin
  Errors := TJSONArray.Create;
  Warnings := TJSONArray.Create;
  Result := 0;

  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    Lines := Output.Replace(#13#10, #10).Split([#10]);

    for Line in Lines do
    begin
      Match := TRegEx.Match(Line, BracketPattern);
      if Match.Success then
      begin
        FileName := Match.Groups[2].Value;
        LineNum := StrToIntDef(Match.Groups[3].Value, 0);
        Code := Match.Groups[4].Value;
        Message := Match.Groups[5].Value;
      end
      else
      begin
        Match := TRegEx.Match(Line, PlainPattern, [roIgnoreCase]);
        if not Match.Success then
          Continue;
        FileName := Match.Groups[1].Value.Trim;
        LineNum := StrToIntDef(Match.Groups[2].Value, 0);
        Code := Match.Groups[4].Value;
        Message := Match.Groups[5].Value;
      end;

      { msbuild prints each diagnostic twice - once inline and again in the
        summary block at the end - so without this every error is counted
        double. }
      Key := Format('%s|%d|%s|%s', [FileName, LineNum, Code, Message]);
      if Seen.IndexOf(Key) >= 0 then
        Continue;
      Seen.Add(Key);

      { Classify by the code letter rather than the severity word: it is the
        compiler's own taxonomy and is consistent across both formats. H is a
        hint - the "directory not found" library-path noise is all H2675, a
        dozen per build - and hints are dropped rather than passed off as
        warnings. }
      case UpCase(Code.Chars[0]) of
        'E', 'F':
          begin
            Entry := TJSONObject.Create;
            Entry.AddPair('file', FileName);
            Entry.AddPair('line', TJSONNumber.Create(LineNum));
            Entry.AddPair('code', Code);
            Entry.AddPair('message', Message);
            Errors.Add(Entry);
            Inc(Result);
          end;
        'W':
          begin
            Entry := TJSONObject.Create;
            Entry.AddPair('file', FileName);
            Entry.AddPair('line', TJSONNumber.Create(LineNum));
            Entry.AddPair('code', Code);
            Entry.AddPair('message', Message);
            Warnings.Add(Entry);
          end;
      end;
    end;
  finally
    Seen.Free;
  end;
end;

{ msbuild's own verdict, which is the only thing that actually knows whether
  the build worked.

  Deriving success from the number of diagnostics we managed to parse means
  any output format we fail to recognise silently becomes "success" - the
  worst possible direction to be wrong in, because an agent reads this field
  and moves on. }
function BuildReportedSuccess(const Output: string): Boolean;
begin
  Result := Output.Contains('Build succeeded') and
            not Output.Contains('Build FAILED');
end;

{ One line the caller can act on without wading through msbuild's output:
  whether it built, the counts, and the compiler's own size/time line. }
function SummariseBuild(const Output: string; ErrorCount, WarningCount: Integer): string;
var
  Line: string;
  Stats: string;
begin
  Stats := '';
  for Line in Output.Replace(#13#10, #10).Split([#10]) do
    if TRegEx.IsMatch(Line, '^\s*\d+ lines, [\d.]+ seconds') then
      Stats := Line.Trim;

  if BuildReportedSuccess(Output) and (ErrorCount = 0) then
    Result := 'Build succeeded'
  else
    Result := 'Build FAILED';
  Result := Format('%s - %d error(s), %d warning(s)',
    [Result, ErrorCount, WarningCount]);
  if Stats <> '' then
    Result := Result + '. ' + Stats;
end;

{ This tool is registered unwrapped, so it runs on the RPC worker thread and
  only steps onto the IDE's main thread for the parts that touch ToolsAPI.
  Marshalling the whole thing would freeze the IDE for the duration of the
  build - minutes, for a real project - and make the UI look hung. }
function ToolCompileProject(Params: TJSONObject): TJSONValue;
var
  BdsRoot, ProjectFile, Config, Platform, CmdLine, Output, WorkDir: string;
  Errors, Warnings: TJSONArray;
  ErrorCount: Integer;
  Obj: TJSONObject;
  SetupError: string;
  IncludeRaw, Succeeded: Boolean;
begin
  SetupError := '';
  RunOnMainThread(
    procedure
    var
      Proj: IOTAProject;
    begin
      try
        Proj := CurrentProject;
        if Proj = nil then
        begin
          SetupError := 'No active project';
          Exit;
        end;
        SaveAllModifiedModules;
        ProjectFile := Proj.FileName;
      except
        on E: Exception do
          SetupError := E.Message;
      end;
    end);
  if SetupError <> '' then
    raise Exception.Create(SetupError);

  WorkDir := ExtractFileDir(ProjectFile);
  BdsRoot := GetBdsRoot;
  if (BdsRoot = '') or not DirectoryExists(BdsRoot) then
    raise Exception.Create('Could not determine RAD Studio install root (BDS)');

  Config := Params.GetValue<string>('config', 'Debug');
  Platform := Params.GetValue<string>('platform', 'Win32');

  CmdLine := Format('cmd.exe /c ""%s\bin\rsvars.bat" && msbuild "%s" /t:Build /p:Config=%s /p:Platform=%s /nologo /v:normal"',
    [BdsRoot, ProjectFile, Config, Platform]);

  Output := RunProcessCaptureOutput(CmdLine, WorkDir, 5 * 60 * 1000);
  ErrorCount := ParseBuildOutput(Output, Errors, Warnings);

  Succeeded := BuildReportedSuccess(Output) and (ErrorCount = 0);

  Obj := TJSONObject.Create;
  Obj.AddPair('success', TJSONBool.Create(Succeeded));
  Obj.AddPair('summary', SummariseBuild(Output, ErrorCount, Warnings.Count));
  Obj.AddPair('errors', Errors);
  Obj.AddPair('warnings', Warnings);
  { Full msbuild output is thousands of lines of library search paths, which is
    a heavy and useless payload on every successful build. Return it only when
    asked for, or when the build failed in a way we could not parse - otherwise
    the caller would be told "it failed" with nothing to act on. }
  IncludeRaw := Params.GetValue<Boolean>('includeRawOutput', False);
  if not IncludeRaw then
    IncludeRaw := not Succeeded and (ErrorCount = 0);
  if IncludeRaw then
    Obj.AddPair('rawOutput', Output);
  Result := Obj;
end;

procedure RegisterBuildTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolCompileProject; RegisterFn('compileProject', F);
end;

end.
