unit RadAiBridge.Tools.Source;

{ Structural edits to Pascal source that would otherwise be fiddly find-and-
  replace work. Adding a unit to a uses clause is the common one: dropping a
  component the designer knows about still leaves the unit missing from the
  form's uses list, and getting that wrong costs a compile round trip.

  There is no ToolsAPI call for this, so it is done on the editor buffer. To
  avoid matching keywords inside comments or string literals, every search runs
  against a mask of the source in which comment and literal bodies are replaced
  by spaces. The mask is the same length as the original, so positions found in
  it index straight back into the real text. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Character,
  ToolsAPI, RadAiBridge.Ide.Utils;

procedure RegisterSourceTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

{ Adds UnitName to FilePath's interface uses clause if it is not already
  there, and reports whether it had to. Exposed so addComponent can pull in
  the unit that declares the class it just dropped, the way the IDE does when
  a component comes off the palette. Silently does nothing when the file is
  not open in the editor. }
function EnsureUnitInUses(const FilePath, UnitName: string): Boolean;

implementation

type
  TMaskState = (msCode, msString, msBraceComment, msParenComment, msLineComment);

function MaskCommentsAndLiterals(const S: string): string;
var
  i: Integer;
  State: TMaskState;
begin
  Result := S;
  State := msCode;
  i := 1;
  while i <= Length(S) do
  begin
    case State of
      msCode:
        begin
          if S[i] = '''' then
            State := msString
          else if S[i] = '{' then
          begin
            State := msBraceComment;
            Result[i] := ' ';
          end
          else if (S[i] = '(') and (i < Length(S)) and (S[i + 1] = '*') then
          begin
            State := msParenComment;
            Result[i] := ' ';
            Inc(i);
            Result[i] := ' ';
          end
          else if (S[i] = '/') and (i < Length(S)) and (S[i + 1] = '/') then
          begin
            State := msLineComment;
            Result[i] := ' ';
          end;
        end;
      msString:
        begin
          { A doubled quote is an escaped quote and keeps us inside the literal;
            the state machine handles it naturally by closing then reopening. }
          if S[i] = '''' then
            State := msCode
          else
            Result[i] := ' ';
        end;
      msBraceComment:
        begin
          if S[i] = '}' then
            State := msCode;
          Result[i] := ' ';
        end;
      msParenComment:
        begin
          if (S[i] = '*') and (i < Length(S)) and (S[i + 1] = ')') then
          begin
            Result[i] := ' ';
            Inc(i);
            State := msCode;
          end;
          Result[i] := ' ';
        end;
      msLineComment:
        begin
          if (S[i] = #13) or (S[i] = #10) then
            State := msCode
          else
            Result[i] := ' ';
        end;
    end;
    Inc(i);
  end;
end;

function IsIdentChar(C: Char): Boolean;
begin
  { '.' counts, so a search for "FMX" does not match inside "FMX.ListBox" and a
    search for "FMX.ListBox" matches the whole dotted name. }
  Result := C.IsLetterOrDigit or (C = '_') or (C = '.');
end;

{ Whole-word, case-insensitive search over the lowercased mask. StopAt of 0
  means "to the end". }
function FindWord(const LowerMask, LowerWord: string; StartAt, StopAt: Integer): Integer;
var
  P, WordLen, Limit: Integer;
begin
  WordLen := Length(LowerWord);
  Limit := StopAt;
  if (Limit <= 0) or (Limit > Length(LowerMask)) then
    Limit := Length(LowerMask);
  P := StartAt;
  while (P > 0) and (P <= Limit) do
  begin
    P := Pos(LowerWord, LowerMask, P);
    if (P = 0) or (P + WordLen - 1 > Limit) then
      Exit(0);
    if ((P = 1) or not IsIdentChar(LowerMask[P - 1])) and
       ((P + WordLen > Length(LowerMask)) or not IsIdentChar(LowerMask[P + WordLen])) then
      Exit(P);
    Inc(P);
  end;
  Result := 0;
end;

{ Returns the source with UnitName added to the named section's uses clause.
  Added is False when it was already there, which is a success, not an error -
  callers add units speculatively after dropping components. }
function AddUnitToUses(const Source, UnitName, Section: string;
  out Added: Boolean): string;
var
  Mask, LowerMask, LowerUnit: string;
  SectionStart, SectionEnd, UsesPos, SemiPos, InsertAt: Integer;
  Indent: string;
begin
  Added := False;
  Result := Source;

  Mask := MaskCommentsAndLiterals(Source);
  LowerMask := LowerCase(Mask);
  LowerUnit := LowerCase(UnitName);

  SectionStart := FindWord(LowerMask, LowerCase(Section), 1, 0);
  if SectionStart = 0 then
    raise Exception.CreateFmt('No "%s" section found in this unit', [Section]);
  SectionStart := SectionStart + Length(Section);

  { The interface section's uses clause must be found before implementation
    begins, or we would edit the wrong one. }
  if SameText(Section, 'interface') then
  begin
    SectionEnd := FindWord(LowerMask, 'implementation', SectionStart, 0);
    if SectionEnd = 0 then
      SectionEnd := Length(Mask);
  end
  else
    SectionEnd := Length(Mask);

  UsesPos := FindWord(LowerMask, 'uses', SectionStart, SectionEnd);

  if UsesPos = 0 then
  begin
    { No uses clause in this section yet - start one directly after the section
      keyword, which is where the compiler requires it. }
    Result := Copy(Source, 1, SectionStart - 1) + sLineBreak + sLineBreak +
      'uses' + sLineBreak + '  ' + UnitName + ';' + sLineBreak +
      Copy(Source, SectionStart, MaxInt);
    Added := True;
    Exit;
  end;

  SemiPos := Pos(';', Mask, UsesPos);
  if (SemiPos = 0) or (SemiPos > SectionEnd) then
    raise Exception.Create('Could not find the end of the uses clause');

  if FindWord(LowerMask, LowerUnit, UsesPos + 4, SemiPos) <> 0 then
    Exit; // already present

  { Insert before the terminating semicolon, matching the clause's existing
    indentation so the result still looks hand-written. }
  InsertAt := SemiPos;
  while (InsertAt > UsesPos) and CharInSet(Source[InsertAt - 1], [' ', #9, #13, #10]) do
    Dec(InsertAt);

  Indent := '  ';
  Result := Copy(Source, 1, InsertAt - 1) + ',' + sLineBreak + Indent + UnitName +
    Copy(Source, InsertAt, MaxInt);
  Added := True;
end;

{ Resolves which file to edit: an explicit path, or the unit behind the form
  currently open in the designer, which is what a caller means when they've
  just dropped a component and need its unit. }
function ResolveSourceEditor(Params: TJSONObject): IOTASourceEditor;
var
  FilePath: string;
  MS: IOTAModuleServices;
  Module: IOTAModule;
  i: Integer;
  Editor: IOTAEditor;
begin
  FilePath := Params.GetValue<string>('filePath', '');
  if FilePath <> '' then
  begin
    Result := FindSourceEditorByFileName(FilePath);
    if Result = nil then
      raise Exception.CreateFmt('File is not open in the IDE: %s', [FilePath]);
    Exit;
  end;

  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('ToolsAPI module services unavailable');
  Module := MS.CurrentModule;
  if Module = nil then
    raise Exception.Create('No current module; pass filePath explicitly');
  for i := 0 to Module.GetModuleFileCount - 1 do
  begin
    Editor := Module.GetModuleFileEditor(i);
    if Supports(Editor, IOTASourceEditor, Result) then
      Exit;
  end;
  raise Exception.Create('The current module has no source editor');
end;

function EnsureUnitInUses(const FilePath, UnitName: string): Boolean;
var
  SourceEditor: IOTASourceEditor;
  Text, NewText: string;
begin
  Result := False;
  if (Trim(FilePath) = '') or (Trim(UnitName) = '') then
    Exit;

  SourceEditor := FindSourceEditorByFileName(FilePath);
  if SourceEditor = nil then
    Exit;

  Text := ReadSourceEditorText(SourceEditor);
  NewText := AddUnitToUses(Text, Trim(UnitName), 'interface', Result);
  if Result then
    WriteSourceEditorText(SourceEditor, NewText);
end;

function ToolAddUsesUnit(Params: TJSONObject): TJSONValue;
var
  SourceEditor: IOTASourceEditor;
  Section, UnitName, Text, NewText: string;
  Added: Boolean;
  Units: TJSONArray;
  Obj: TJSONObject;
  Names: TArray<string>;
  i: Integer;
  AnyAdded: Boolean;
begin
  SourceEditor := ResolveSourceEditor(Params);
  Section := Params.GetValue<string>('section', 'interface');
  if not (SameText(Section, 'interface') or SameText(Section, 'implementation')) then
    raise Exception.Create('section must be "interface" or "implementation"');

  { Accept either one unit or a list - adding a component usually pulls in
    several, and rewriting the buffer once keeps undo history tidy. }
  if Params.GetValue('unitNames') is TJSONArray then
  begin
    Units := Params.GetValue('unitNames') as TJSONArray;
    SetLength(Names, Units.Count);
    for i := 0 to Units.Count - 1 do
      Names[i] := Units.Items[i].Value;
  end
  else
    Names := [Params.GetValue<string>('unitName')];

  Text := ReadSourceEditorText(SourceEditor);
  AnyAdded := False;
  Obj := TJSONObject.Create;
  for UnitName in Names do
  begin
    if Trim(UnitName) = '' then
      Continue;
    NewText := AddUnitToUses(Text, Trim(UnitName), Section, Added);
    Text := NewText;
    if Added then
      AnyAdded := True;
    Obj.AddPair(Trim(UnitName), TJSONBool.Create(Added));
  end;

  if AnyAdded then
    WriteSourceEditorText(SourceEditor, Text);

  Result := TJSONObject.Create;
  TJSONObject(Result).AddPair('fileName', SourceEditor.FileName);
  TJSONObject(Result).AddPair('section', Section);
  TJSONObject(Result).AddPair('added', Obj);
end;

procedure RegisterSourceTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolAddUsesUnit; RegisterFn('addUsesUnit', F);
end;

end.
