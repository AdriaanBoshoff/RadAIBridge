unit RadAiBridge.Ide.Utils;

{ Small shared helpers over ToolsAPI used by all tool modules. }

interface

uses
  System.SysUtils, System.Classes, ToolsAPI;

function ModuleServices: IOTAModuleServices;
function ActionServices: IOTAActionServices;
function MessageServices: IOTAMessageServices;
function ProjectGroup: IOTAProjectGroup;
function CurrentProject: IOTAProject;
function FindSourceEditorByFileName(const FileName: string): IOTASourceEditor;
function ReadSourceEditorText(SourceEditor: IOTASourceEditor): string;
procedure WriteSourceEditorText(SourceEditor: IOTASourceEditor; const Text: string);

implementation

function ModuleServices: IOTAModuleServices;
begin
  Supports(BorlandIDEServices, IOTAModuleServices, Result);
end;

function ActionServices: IOTAActionServices;
begin
  Supports(BorlandIDEServices, IOTAActionServices, Result);
end;

function MessageServices: IOTAMessageServices;
begin
  Supports(BorlandIDEServices, IOTAMessageServices, Result);
end;

function ProjectGroup: IOTAProjectGroup;
var
  MS: IOTAModuleServices;
begin
  Result := nil;
  MS := ModuleServices;
  if MS <> nil then
    Result := MS.GetMainProjectGroup;
end;

function CurrentProject: IOTAProject;
var
  Group: IOTAProjectGroup;
begin
  Result := nil;
  Group := ProjectGroup;
  if Group <> nil then
    Result := Group.ActiveProject;
end;

function FindSourceEditorByFileName(const FileName: string): IOTASourceEditor;
var
  MS: IOTAModuleServices;
  Module: IOTAModule;
  Editor: IOTAEditor;
  j: Integer;
begin
  Result := nil;
  MS := ModuleServices;
  if MS = nil then
    Exit;
  Module := MS.FindModule(FileName);
  if Module = nil then
    Exit;
  for j := 0 to Module.GetModuleFileCount - 1 do
  begin
    Editor := Module.GetModuleFileEditor(j);
    if SameFileName(Editor.FileName, FileName) and Supports(Editor, IOTASourceEditor, Result) then
      Exit;
  end;
end;

function ReadSourceEditorText(SourceEditor: IOTASourceEditor): string;
const
  BufSize = 8192;
var
  Reader: IOTAEditReader;
  Buffer: array[0..BufSize - 1] of AnsiChar;
  Read: Integer;
  Position: Integer;
  RawBytes: TBytes;
  SS: TBytesStream;
begin
  Reader := SourceEditor.CreateReader;
  SS := TBytesStream.Create;
  try
    Position := 0;
    repeat
      Read := Reader.GetText(Position, Buffer, BufSize);
      if Read > 0 then
      begin
        SS.Write(Buffer, Read);
        Inc(Position, Read);
      end;
    until Read <= 0;
    RawBytes := SS.Bytes;
    SetLength(RawBytes, SS.Size);
    Result := TEncoding.UTF8.GetString(RawBytes);
  finally
    SS.Free;
  end;
end;

procedure WriteSourceEditorText(SourceEditor: IOTASourceEditor; const Text: string);
var
  Writer: IOTAEditWriter;
  Utf8: UTF8String;
begin
  Writer := SourceEditor.CreateUndoableWriter;
  Writer.DeleteTo(MaxInt);
  Utf8 := UTF8String(Text);
  if Length(Utf8) > 0 then
    Writer.Insert(Utf8);
end;

end.
