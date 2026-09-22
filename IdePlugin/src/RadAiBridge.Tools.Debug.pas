unit RadAiBridge.Tools.Debug;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.TypInfo,
  System.Actions, Vcl.ActnList, ToolsAPI, RadAiBridge.Ide.Utils;

procedure RegisterDebugTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

function DebuggerServices: IOTADebuggerServices;
begin
  Supports(BorlandIDEServices, IOTADebuggerServices, Result);
end;

{ Run and stepping used to go through IOTAEditActions off Module.CurrentEditor.
  That could not work: IOTAEditActions is implemented by the edit *buffer*, not
  by IOTAEditor, so the cast always failed - and it made a whole-application
  command depend on a source editor happening to be focused, which it is not
  when the Designer is in front.

  The IDE's own action list is the thing that actually drives Run/Step, needs no
  editor, and is exactly what the menu items and keyboard shortcuts invoke. }
function FindIdeAction(const ActionName: string): TContainedAction;
var
  NTA: INTAServices;
  i: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, INTAServices, NTA) then
    Exit;
  if NTA.ActionList = nil then
    Exit;
  for i := 0 to NTA.ActionList.ActionCount - 1 do
    if SameText(NTA.ActionList.Actions[i].Name, ActionName) then
      Exit(NTA.ActionList.Actions[i]);
end;

{ Tries each candidate in turn, because the IDE's action names are not part of
  any published contract and have moved between releases. }
procedure ExecuteIdeAction(const Candidates: array of string;
  const Description: string);
var
  Name: string;
  Action: TContainedAction;
  Tried: string;
begin
  Tried := '';
  for Name in Candidates do
  begin
    Action := FindIdeAction(Name);
    if Action <> nil then
    begin
      if not Action.Enabled then
        raise Exception.CreateFmt(
          '%s is not available right now (the IDE has "%s" disabled - there may ' +
          'be no active project, or the program may not be running).',
          [Description, Name]);
      Action.Execute;
      Exit;
    end;
    if Tried <> '' then
      Tried := Tried + ', ';
    Tried := Tried + Name;
  end;
  raise Exception.CreateFmt(
    'Could not find the IDE action for %s (looked for: %s)', [Description, Tried]);
end;

{ Diagnostic: the IDE action names are undocumented and differ between releases,
  so rather than guessing one per IDE restart, this dumps what is actually
  registered. Filter with "contains" to keep the payload small. }
function ToolListIdeActions(Params: TJSONObject): TJSONValue;
var
  NTA: INTAServices;
  Filter, Haystack: string;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Action: TContainedAction;
  i: Integer;
begin
  Arr := TJSONArray.Create;
  Filter := Params.GetValue<string>('contains', '');
  if Supports(BorlandIDEServices, INTAServices, NTA) and (NTA.ActionList <> nil) then
    for i := 0 to NTA.ActionList.ActionCount - 1 do
    begin
      Action := NTA.ActionList.Actions[i];
      if (Filter <> '') then
      begin
        Haystack := Action.Name;
        if Action is TCustomAction then
          Haystack := Haystack + ' ' + TCustomAction(Action).Caption;
        if not Haystack.ToLower.Contains(Filter.ToLower) then
          Continue;
      end;
      Entry := TJSONObject.Create;
      Entry.AddPair('name', Action.Name);
      if Action is TCustomAction then
        Entry.AddPair('caption', TCustomAction(Action).Caption);
      Entry.AddPair('enabled', TJSONBool.Create(Action.Enabled));
      Arr.Add(Entry);
    end;
  Result := Arr;
end;

function ToolRunProject(Params: TJSONObject): TJSONValue;
begin
  ExecuteIdeAction(['RunRunCommand', 'RunRun'], 'Run');
  Result := TJSONBool.Create(True);
end;

function ToolStepOver(Params: TJSONObject): TJSONValue;
begin
  ExecuteIdeAction(['RunStepOverCommand', 'RunStepOver'], 'Step Over');
  Result := TJSONBool.Create(True);
end;

function ToolStepInto(Params: TJSONObject): TJSONValue;
begin
  ExecuteIdeAction(['RunTraceIntoCommand', 'RunTraceInto'], 'Step Into');
  Result := TJSONBool.Create(True);
end;

{ The missing third of the stepping trio - the IDE has always had it as
  Run Until Return; only the tool was absent. }
function ToolStepOut(Params: TJSONObject): TJSONValue;
begin
  ExecuteIdeAction(['RunUntilReturnCommand'], 'Step Out');
  Result := TJSONBool.Create(True);
end;

function ToolRunToCursor(Params: TJSONObject): TJSONValue;
begin
  ExecuteIdeAction(['RunGotoCursorCommand', 'RunRunToCursor'], 'Run To Cursor');
  Result := TJSONBool.Create(True);
end;

function ToolTerminateProcess(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
begin
  DS := DebuggerServices;
  if (DS <> nil) and (DS.CurrentProcess <> nil) then
    DS.CurrentProcess.Terminate
  else
    ExecuteIdeAction(['RunResetCommand', 'RunProgramReset'], 'Program Reset');
  Result := TJSONBool.Create(True);
end;

function ToolAddBreakpoint(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
  FilePath: string;
  Line: Integer;
  Bp: IOTABreakpoint;
begin
  DS := DebuggerServices;
  if DS = nil then
    raise Exception.Create('Debugger services unavailable');
  FilePath := Params.GetValue<string>('filePath');
  Line := Params.GetValue<Integer>('line');
  Bp := DS.NewSourceBreakpoint(FilePath, Line, nil);
  if Bp = nil then
    raise Exception.Create('Failed to create breakpoint');
  Result := TJSONBool.Create(True);
end;

function FindSourceBreakpoint(DS: IOTADebuggerServices; const FilePath: string; Line: Integer): IOTABreakpoint;
var
  i: Integer;
  Bp: IOTASourceBreakpoint;
begin
  Result := nil;
  for i := 0 to DS.SourceBkptCount - 1 do
  begin
    Bp := DS.SourceBkpts[i];
    if SameFileName(Bp.FileName, FilePath) and (Bp.LineNumber = Line) then
      Exit(Bp);
  end;
end;

function ToolRemoveBreakpoint(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
  FilePath: string;
  Line: Integer;
  Bp: IOTABreakpoint;
begin
  DS := DebuggerServices;
  if DS = nil then
    raise Exception.Create('Debugger services unavailable');
  FilePath := Params.GetValue<string>('filePath');
  Line := Params.GetValue<Integer>('line');
  Bp := FindSourceBreakpoint(DS, FilePath, Line);
  if Bp = nil then
    raise Exception.CreateFmt('No breakpoint at %s:%d', [FilePath, Line]);
  DS.RemoveBreakpoint(Bp);
  Result := TJSONBool.Create(True);
end;

function ToolRemoveAllBreakpoints(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
  i: Integer;
begin
  DS := DebuggerServices;
  if DS = nil then
    raise Exception.Create('Debugger services unavailable');
  for i := DS.SourceBkptCount - 1 downto 0 do
    DS.RemoveBreakpoint(DS.SourceBkpts[i]);
  Result := TJSONBool.Create(True);
end;

function ToolListBreakpoints(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
  Arr: TJSONArray;
  Entry: TJSONObject;
  i: Integer;
  Bp: IOTASourceBreakpoint;
begin
  DS := DebuggerServices;
  Arr := TJSONArray.Create;
  if DS <> nil then
    for i := 0 to DS.SourceBkptCount - 1 do
    begin
      Bp := DS.SourceBkpts[i];
      Entry := TJSONObject.Create;
      Entry.AddPair('filePath', Bp.FileName);
      Entry.AddPair('line', TJSONNumber.Create(Bp.LineNumber));
      Entry.AddPair('enabled', TJSONBool.Create(Bp.Enabled));
      Arr.Add(Entry);
    end;
  Result := Arr;
end;

{ CallHeaders/GetCallPos are ONE-based - "the first item in the list is at
  index 1". Walking them from 0 reaches into the debug kernel below the first
  frame, which trips an assertion ("item.src", DBKIMPL.CPP) and puts up a modal
  error dialog. That dialog then blocks the IDE main thread, so the symptom is
  a hung bridge rather than anything that points at the indexing.

  The thread must also actually be stopped: querying the stack of a running
  thread is what csWait/csInaccessible are there to tell us. }
function ToolGetCallStack(Params: TJSONObject): TJSONValue;
var
  DS: IOTADebuggerServices;
  Thread: IOTAThread;
  Arr: TJSONArray;
  Frame: TJSONObject;
  i, Count, MaxFrames, LineNum: Integer;
  FileName: string;
  Obj: TJSONObject;
  Access: TOTACallStackState;
begin
  DS := DebuggerServices;
  if (DS = nil) or (DS.CurrentProcess = nil) then
    raise Exception.Create('No process is currently being debugged');
  Thread := DS.CurrentProcess.CurrentThread;
  if Thread = nil then
    raise Exception.Create('No current thread');
  if Thread.State <> tsStopped then
    raise Exception.Create(
      'The current thread is not stopped, so its call stack cannot be read. ' +
      'Pause the program or wait for a breakpoint first.');

  MaxFrames := Params.GetValue<Integer>('maxFrames', 64);

  Obj := TJSONObject.Create;
  Obj.AddPair('currentFile', Thread.CurrentFile);
  Obj.AddPair('currentLine', TJSONNumber.Create(Thread.CurrentLine));

  Arr := TJSONArray.Create;
  Access := Thread.StartCallStackAccess;
  if Access = csAccessible then
  begin
    try
      { GetCallCount must be called before GetCallHeader. }
      Count := Thread.CallCount;
      if (MaxFrames > 0) and (Count > MaxFrames) then
        Count := MaxFrames;
      for i := 1 to Count do
      begin
        Frame := TJSONObject.Create;
        Frame.AddPair('header', Thread.CallHeaders[i]);
        Thread.GetCallPos(i, FileName, LineNum);
        if FileName <> '' then
        begin
          Frame.AddPair('file', FileName);
          Frame.AddPair('line', TJSONNumber.Create(LineNum));
        end;
        Arr.Add(Frame);
      end;
      Obj.AddPair('totalFrames', TJSONNumber.Create(Thread.CallCount));
    finally
      Thread.EndCallStackAccess;
    end;
  end
  else
    Obj.AddPair('stackAccess',
      GetEnumName(TypeInfo(TOTACallStackState), Ord(Access)));
  Obj.AddPair('frames', Arr);
  Result := Obj;
end;

function ToolEvaluateExpression(Params: TJSONObject): TJSONValue;
const
  BufSize = 8192;
var
  DS: IOTADebuggerServices;
  Thread: IOTAThread;
  Expr: string;
  ResultBuf: array[0..BufSize - 1] of Char;
  CanModify: Boolean;
  ResultAddr, ResultSize, ResultVal: LongWord;
  EvalResult: TOTAEvaluateResult;
  Obj: TJSONObject;
begin
  DS := DebuggerServices;
  if (DS = nil) or (DS.CurrentProcess = nil) then
    raise Exception.Create('No process is currently being debugged');
  Thread := DS.CurrentProcess.CurrentThread;
  if Thread = nil then
    raise Exception.Create('No current thread');
  if Thread.State <> tsStopped then
    raise Exception.Create(
      'The current thread is not stopped, so expressions cannot be evaluated. ' +
      'Pause the program or wait for a breakpoint first.');

  Expr := Params.GetValue<string>('expression');
  FillChar(ResultBuf, SizeOf(ResultBuf), 0);
  EvalResult := Thread.Evaluate(Expr, @ResultBuf[0], BufSize, CanModify, True, nil,
    ResultAddr, ResultSize, ResultVal);

  Obj := TJSONObject.Create;
  Obj.AddPair('status', TJSONString.Create(GetEnumName(TypeInfo(TOTAEvaluateResult), Ord(EvalResult))));
  Obj.AddPair('value', TJSONString.Create(string(ResultBuf)));
  Result := Obj;
end;

procedure RegisterDebugTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolListIdeActions;          RegisterFn('listIdeActions', F);
  F := ToolRunProject;              RegisterFn('runProject', F);
  F := ToolStepOver;                RegisterFn('stepOver', F);
  F := ToolStepInto;                RegisterFn('stepInto', F);
  F := ToolStepOut;                 RegisterFn('stepOut', F);
  F := ToolRunToCursor;             RegisterFn('runToCursor', F);
  F := ToolTerminateProcess;        RegisterFn('terminateProcess', F);
  F := ToolAddBreakpoint;           RegisterFn('addBreakpoint', F);
  F := ToolRemoveBreakpoint;        RegisterFn('removeBreakpoint', F);
  F := ToolRemoveAllBreakpoints;    RegisterFn('removeAllBreakpoints', F);
  F := ToolListBreakpoints;         RegisterFn('listBreakpoints', F);
  F := ToolGetCallStack;            RegisterFn('getCallStack', F);
  F := ToolEvaluateExpression;      RegisterFn('evaluateExpression', F);
end;

end.
