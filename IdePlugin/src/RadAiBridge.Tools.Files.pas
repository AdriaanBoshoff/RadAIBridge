unit RadAiBridge.Tools.Files;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Math, System.IOUtils,
  ToolsAPI, RadAiBridge.Ide.Utils;

procedure RegisterFileTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

function ToolListOpenFiles(Params: TJSONObject): TJSONValue;
var
  MS: IOTAModuleServices;
  Module: IOTAModule;
  Editor: IOTAEditor;
  Arr: TJSONArray;
  i, j: Integer;
begin
  Arr := TJSONArray.Create;
  MS := ModuleServices;
  if MS <> nil then
    for i := 0 to MS.ModuleCount - 1 do
    begin
      Module := MS.Modules[i];
      for j := 0 to Module.GetModuleFileCount - 1 do
      begin
        Editor := Module.GetModuleFileEditor(j);
        if (Editor <> nil) and (Editor.FileName <> '') then
          Arr.Add(Editor.FileName);
      end;
    end;
  Result := Arr;
end;

function ToolGetEditorContent(Params: TJSONObject): TJSONValue;
var
  FilePath: string;
  SourceEditor: IOTASourceEditor;
begin
  FilePath := Params.GetValue<string>('filePath');
  SourceEditor := FindSourceEditorByFileName(FilePath);
  if SourceEditor <> nil then
    Result := TJSONString.Create(ReadSourceEditorText(SourceEditor))
  else
    Result := TJSONString.Create(TFile.ReadAllText(FilePath, TEncoding.UTF8));
end;

function ToolGetEditorLines(Params: TJSONObject): TJSONValue;
var
  FilePath, FullText: string;
  SourceEditor: IOTASourceEditor;
  Lines: TArray<string>;
  StartLine, LineCount, i, LastIdx: Integer;
  Arr: TJSONArray;
begin
  FilePath := Params.GetValue<string>('filePath');
  StartLine := Params.GetValue<Integer>('startLine', 1);
  LineCount := Params.GetValue<Integer>('lineCount', 200);

  SourceEditor := FindSourceEditorByFileName(FilePath);
  if SourceEditor <> nil then
    FullText := ReadSourceEditorText(SourceEditor)
  else
    FullText := TFile.ReadAllText(FilePath, TEncoding.UTF8);

  Lines := FullText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  Arr := TJSONArray.Create;
  if StartLine < 1 then
    StartLine := 1;
  LastIdx := Min(StartLine + LineCount - 1, Length(Lines));
  for i := StartLine to LastIdx do
    Arr.Add(Lines[i - 1]);
  Result := Arr;
end;

function ToolSetEditorContent(Params: TJSONObject): TJSONValue;
var
  FilePath, Content: string;
  SourceEditor: IOTASourceEditor;
begin
  FilePath := Params.GetValue<string>('filePath');
  Content := Params.GetValue<string>('content');
  SourceEditor := FindSourceEditorByFileName(FilePath);
  if SourceEditor <> nil then
    WriteSourceEditorText(SourceEditor, Content)
  else
    TFile.WriteAllText(FilePath, Content, TEncoding.UTF8);
  Result := TJSONBool.Create(True);
end;

{ Collapses CRLF and lone CR to LF so text from two sources can be compared. }
function NormaliseEol(const S: string): string;
begin
  Result := S.Replace(#13#10, #10).Replace(#13, #10);
end;

{ Matching is done on line-ending-normalised text.

  Delphi source buffers are CRLF. A caller sending LF - which is everything
  that composes source as ordinary text - could never match anything spanning
  more than one line, so applyEdit failed on every multi-line edit and worked
  only on single-line ones. That is a confusing failure, because the text
  quite visibly *is* in the file.

  The buffer's own convention is restored before writing, so normalising for
  the comparison does not quietly rewrite every line ending in the file. }
function ToolApplyEdit(Params: TJSONObject): TJSONValue;
var
  FilePath, OldContent, NewContent, FullText: string;
  NormText, NormOld, NormNew, Updated: string;
  SourceEditor: IOTASourceEditor;
  P: Integer;
  FromDisk, WasCrLf: Boolean;
begin
  FilePath := Params.GetValue<string>('filePath');
  OldContent := Params.GetValue<string>('oldContent');
  NewContent := Params.GetValue<string>('newContent');

  SourceEditor := FindSourceEditorByFileName(FilePath);
  FromDisk := SourceEditor = nil;
  if not FromDisk then
    FullText := ReadSourceEditorText(SourceEditor)
  else
    FullText := TFile.ReadAllText(FilePath, TEncoding.UTF8);

  WasCrLf := FullText.Contains(#13#10);
  NormText := NormaliseEol(FullText);
  NormOld := NormaliseEol(OldContent);
  NormNew := NormaliseEol(NewContent);

  if NormOld = '' then
    raise Exception.Create('oldContent must not be empty');

  P := Pos(NormOld, NormText);
  if P = 0 then
    raise Exception.Create('oldContent not found in file - it must match exactly, ' +
      'including whitespace (line endings are ignored). Re-read the file first.');
  if Pos(NormOld, NormText, P + 1) > 0 then
    raise Exception.Create('oldContent is not unique in the file - include more ' +
      'surrounding context so the match is unambiguous.');

  Updated := Copy(NormText, 1, P - 1) + NormNew +
             Copy(NormText, P + Length(NormOld), MaxInt);

  if WasCrLf then
    Updated := Updated.Replace(#10, #13#10);

  if not FromDisk then
    WriteSourceEditorText(SourceEditor, Updated)
  else
    TFile.WriteAllText(FilePath, Updated, TEncoding.UTF8);
  Result := TJSONBool.Create(True);
end;

function ToolOpenFile(Params: TJSONObject): TJSONValue;
var
  FilePath: string;
  ShowIt: Boolean;
  AS_: IOTAActionServices;
begin
  FilePath := Params.GetValue<string>('filePath');
  ShowIt := Params.GetValue<Boolean>('show', True);
  AS_ := ActionServices;
  if AS_ = nil then
    raise Exception.Create('Action services unavailable');
  if ShowIt then
    Result := TJSONBool.Create(AS_.OpenFile(FilePath))
  else
    Result := TJSONBool.Create(ModuleServices.OpenModule(FilePath) <> nil);
end;

{ Without this, edits only reach disk as a side effect of compileProject, so an
  agent that edits and then stops leaves work sitting in unsaved buffers - and
  an unsaved buffer is one of the things that later pops a blocking modal.

  Save(ChangeName, ForceSave): ForceSave=True is what suppresses the
  "Save changes to X?" confirmation. There is no "prompt" parameter. }
function ToolSaveFile(Params: TJSONObject): TJSONValue;
var
  FilePath: string;
  MS: IOTAModuleServices;
  Module: IOTAModule;
  Group: IOTAProjectGroup;
  Saved: TJSONArray;
  i: Integer;
begin
  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('Module services unavailable');

  FilePath := Params.GetValue<string>('filePath', '');
  Saved := TJSONArray.Create;

  if FilePath <> '' then
  begin
    Module := MS.FindModule(FilePath);
    if Module = nil then
      raise Exception.CreateFmt('%s is not open in the IDE', [FilePath]);
    Module.Save(False, True);
    Saved.Add(Module.FileName);
  end
  else
  begin
    { Save everything. Project groups are IDE bookkeeping rather than build
      input, and an unsaved one pops a modal "Save As" that would block the
      call; a module never written to disk has no filename to save to. Skip
      both rather than inventing a path on the user's behalf. }
    for i := 0 to MS.ModuleCount - 1 do
    begin
      Module := MS.Modules[i];
      if Supports(Module, IOTAProjectGroup, Group) then
        Continue;
      if not TPath.IsPathRooted(Module.FileName) then
        Continue;
      Module.Save(False, True);
      Saved.Add(Module.FileName);
    end;
  end;

  Result := TJSONObject.Create.AddPair('saved', Saved);
end;

procedure RegisterFileTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolListOpenFiles;       RegisterFn('listOpenFiles', F);
  F := ToolGetEditorContent;    RegisterFn('getEditorContent', F);
  F := ToolGetEditorLines;      RegisterFn('getEditorLines', F);
  F := ToolSetEditorContent;    RegisterFn('setEditorContent', F);
  F := ToolApplyEdit;           RegisterFn('applyEdit', F);
  F := ToolOpenFile;            RegisterFn('openFile', F);
  F := ToolSaveFile;            RegisterFn('saveFile', F);
end;

end.
