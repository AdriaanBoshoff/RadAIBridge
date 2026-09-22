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

function ToolApplyEdit(Params: TJSONObject): TJSONValue;
var
  FilePath, OldContent, NewContent, FullText: string;
  SourceEditor: IOTASourceEditor;
  P: Integer;
  FromDisk: Boolean;
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

  P := Pos(OldContent, FullText);
  if P = 0 then
    raise Exception.Create('oldContent not found in file - it must match exactly, ' +
      'including whitespace. Re-read the file first.');
  if Pos(OldContent, FullText, P + 1) > 0 then
    raise Exception.Create('oldContent is not unique in the file - include more ' +
      'surrounding context so the match is unambiguous.');

  FullText := Copy(FullText, 1, P - 1) + NewContent + Copy(FullText, P + Length(OldContent), MaxInt);

  if not FromDisk then
    WriteSourceEditorText(SourceEditor, FullText)
  else
    TFile.WriteAllText(FilePath, FullText, TEncoding.UTF8);
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
end;

end.
