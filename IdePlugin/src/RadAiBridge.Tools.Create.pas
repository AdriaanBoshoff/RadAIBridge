unit RadAiBridge.Tools.Create;

{ Creating new modules through the IDE rather than writing .pas files to disk
  and adding them afterwards. Going through IOTAModuleCreator is what makes the
  new unit a real member of the project: it lands in the Project Manager, gets
  a live editor buffer, and - for forms - gets a designer and a paired
  .fmx/.dfm, none of which happen if you just drop text on disk. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils,
  ToolsAPI, RadAiBridge.Ide.Utils;

procedure RegisterCreateTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

type
  { Minimal IOTAFile wrapper - the IDE only ever asks a creator for source text
    and a timestamp, and for brand-new files the timestamp is by convention -1. }
  TSourceFile = class(TInterfacedObject, IOTAFile)
  private
    FSource: string;
  public
    constructor Create(const ASource: string);
    function GetSource: string;
    function GetAge: TDateTime;
  end;

  TModuleCreator = class(TInterfacedObject, IOTACreator, IOTAModuleCreator)
  private
    FUnitName: string;
    FFormIdent: string;
    FAncestorName: string;
    FImplFileName: string;
    FSource: string;
    FIsForm: Boolean;
    FShowSource: Boolean;
  public
    constructor Create(const AUnitName, AFormIdent, AAncestorName,
      AImplFileName, ASource: string; AIsForm, AShowSource: Boolean);
    { IOTACreator }
    function GetCreatorType: string;
    function GetExisting: Boolean;
    function GetFileSystem: string;
    function GetOwner: IOTAModule;
    function GetUnnamed: Boolean;
    { IOTAModuleCreator }
    function GetAncestorName: string;
    function GetImplFileName: string;
    function GetIntfFileName: string;
    function GetFormName: string;
    function GetMainForm: Boolean;
    function GetShowForm: Boolean;
    function GetShowSource: Boolean;
    function NewFormFile(const FormIdent, AncestorIdent: string): IOTAFile;
    function NewImplSource(const ModuleIdent, FormIdent, AncestorIdent: string): IOTAFile;
    function NewIntfSource(const ModuleIdent, FormIdent, AncestorIdent: string): IOTAFile;
    procedure FormCreated(const FormEditor: IOTAFormEditor);
  end;

  TProjectCreator = class(TInterfacedObject, IOTACreator, IOTAProjectCreator,
    IOTAProjectCreator50, IOTAProjectCreator80, IOTAProjectCreator160,
    IOTAProjectCreator190)
  private
    FFileName: string;
    FFrameworkType: string;
    FProjectType: string;
    FPlatforms: TArray<string>;
    FPreferredPlatform: string;
  public
    constructor Create(const AFileName, AFrameworkType, AProjectType,
      APreferredPlatform: string; const APlatforms: TArray<string>);
    { IOTACreator }
    function GetCreatorType: string;
    function GetExisting: Boolean;
    function GetFileSystem: string;
    function GetOwner: IOTAModule;
    function GetUnnamed: Boolean;
    { IOTAProjectCreator }
    function GetFileName: string;
    function GetOptionFileName: string;
    function GetShowSource: Boolean;
    procedure NewDefaultModule;
    function NewOptionSource(const ProjectName: string): IOTAFile;
    procedure NewProjectResource(const Project: IOTAProject);
    function NewProjectSource(const ProjectName: string): IOTAFile;
    { IOTAProjectCreator50 }
    procedure NewDefaultProjectModule(const Project: IOTAProject);
    { IOTAProjectCreator80 }
    function GetProjectPersonality: string;
    { IOTAProjectCreator160 }
    function GetFrameworkType: string;
    function GetPlatforms: TArray<string>;
    function GetPreferredPlatform: string;
    procedure SetInitialOptions(const NewProject: IOTAProject);
    { IOTAProjectCreator190 }
    function GetSupportedPlatforms: TArray<string>;
  end;

function ProjectSource(const ProgramIdent, Framework, ProjectType: string): string; forward;

{ TSourceFile }

constructor TSourceFile.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
end;

function TSourceFile.GetSource: string;
begin
  Result := FSource;
end;

function TSourceFile.GetAge: TDateTime;
begin
  Result := -1;
end;

{ TModuleCreator }

constructor TModuleCreator.Create(const AUnitName, AFormIdent, AAncestorName,
  AImplFileName, ASource: string; AIsForm, AShowSource: Boolean);
begin
  inherited Create;
  FUnitName := AUnitName;
  FFormIdent := AFormIdent;
  FAncestorName := AAncestorName;
  FImplFileName := AImplFileName;
  FSource := ASource;
  FIsForm := AIsForm;
  FShowSource := AShowSource;
end;

function TModuleCreator.GetCreatorType: string;
begin
  if FIsForm then
    Result := sForm
  else
    Result := sUnit;
end;

function TModuleCreator.GetExisting: Boolean;
begin
  Result := False;
end;

function TModuleCreator.GetFileSystem: string;
begin
  Result := '';
end;

function TModuleCreator.GetOwner: IOTAModule;
begin
  { Owning the module to the active project is what puts it in the .dproj.
    A nil owner still creates the file, but as a stray unit nobody builds. }
  Result := CurrentProject;
end;

function TModuleCreator.GetUnnamed: Boolean;
begin
  { False means "I supplied a real filename" - otherwise the IDE treats the
    module as untitled and prompts for Save As on the first save. }
  Result := FImplFileName = '';
end;

function TModuleCreator.GetAncestorName: string;
begin
  Result := FAncestorName;
end;

function TModuleCreator.GetImplFileName: string;
begin
  Result := FImplFileName;
end;

function TModuleCreator.GetIntfFileName: string;
begin
  { Delphi has no separate interface file; that's a C++Builder concept. }
  Result := '';
end;

function TModuleCreator.GetFormName: string;
begin
  Result := FFormIdent;
end;

function TModuleCreator.GetMainForm: Boolean;
begin
  Result := False;
end;

function TModuleCreator.GetShowForm: Boolean;
begin
  Result := FIsForm;
end;

function TModuleCreator.GetShowSource: Boolean;
begin
  Result := FShowSource;
end;

function TModuleCreator.NewFormFile(const FormIdent, AncestorIdent: string): IOTAFile;
begin
  { nil lets the IDE stream a default empty form of the project's own
    framework, which is what picks .fmx over .dfm. Supplying text here would
    mean guessing that choice ourselves. }
  Result := nil;
end;

function TModuleCreator.NewImplSource(const ModuleIdent, FormIdent,
  AncestorIdent: string): IOTAFile;
begin
  Result := TSourceFile.Create(FSource);
end;

function TModuleCreator.NewIntfSource(const ModuleIdent, FormIdent,
  AncestorIdent: string): IOTAFile;
begin
  Result := nil;
end;

procedure TModuleCreator.FormCreated(const FormEditor: IOTAFormEditor);
begin
  // Nothing to adjust; the designer tools handle the form's contents.
end;

{ TProjectCreator }

constructor TProjectCreator.Create(const AFileName, AFrameworkType,
  AProjectType, APreferredPlatform: string; const APlatforms: TArray<string>);
begin
  inherited Create;
  FFileName := AFileName;
  FFrameworkType := AFrameworkType;
  FProjectType := AProjectType;
  FPreferredPlatform := APreferredPlatform;
  FPlatforms := APlatforms;
end;

function TProjectCreator.GetCreatorType: string;
begin
  Result := FProjectType;
end;

function TProjectCreator.GetExisting: Boolean;
begin
  Result := False;
end;

function TProjectCreator.GetFileSystem: string;
begin
  Result := '';
end;

function TProjectCreator.GetOwner: IOTAModule;
begin
  { Owning the new project to the current project group adds it alongside what
    is already open instead of replacing it. }
  Result := ProjectGroup;
end;

function TProjectCreator.GetUnnamed: Boolean;
begin
  Result := False;
end;

function TProjectCreator.GetFileName: string;
begin
  Result := FFileName;
end;

function TProjectCreator.GetOptionFileName: string;
begin
  Result := '';
end;

function TProjectCreator.GetShowSource: Boolean;
begin
  Result := False;
end;

procedure TProjectCreator.NewDefaultModule;
begin
  // Deprecated; NewDefaultProjectModule is the live entry point.
end;

function TProjectCreator.NewOptionSource(const ProjectName: string): IOTAFile;
begin
  Result := nil;
end;

procedure TProjectCreator.NewProjectResource(const Project: IOTAProject);
begin
  // The IDE generates the default .res itself.
end;

function TProjectCreator.NewProjectSource(const ProjectName: string): IOTAFile;
begin
  Result := TSourceFile.Create(
    ProjectSource(ProjectName, FFrameworkType, FProjectType));
end;

procedure TProjectCreator.NewDefaultProjectModule(const Project: IOTAProject);
begin
  { Deliberately empty: the caller adds forms and units explicitly with
    createForm/createUnit, so a surprise default Unit1 would just be noise. }
end;

function TProjectCreator.GetProjectPersonality: string;
begin
  Result := sDelphiPersonality;
end;

function TProjectCreator.GetFrameworkType: string;
begin
  Result := FFrameworkType;
end;

function TProjectCreator.GetPlatforms: TArray<string>;
begin
  Result := FPlatforms;
end;

function TProjectCreator.GetSupportedPlatforms: TArray<string>;
begin
  Result := FPlatforms;
end;

function TProjectCreator.GetPreferredPlatform: string;
begin
  Result := FPreferredPlatform;
end;

procedure TProjectCreator.SetInitialOptions(const NewProject: IOTAProject);
begin
  // Defaults are fine; callers tune them with setProjectOption afterwards.
end;

{ Source templates }

function PlainUnitSource(const UnitName, Body: string): string;
begin
  Result :=
    'unit ' + UnitName + ';'#13#10 +
    #13#10 +
    'interface'#13#10 +
    #13#10 +
    'implementation'#13#10 +
    #13#10 +
    Body +
    'end.'#13#10;
end;

function FormUnitSource(const UnitName, FormIdent, Framework: string): string;
var
  FormClass, UsesClause, ResourceDirective: string;
begin
  FormClass := 'T' + FormIdent;
  if SameText(Framework, 'VCL') then
  begin
    UsesClause :=
      '  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,'#13#10 +
      '  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs;';
    ResourceDirective := '{$R *.dfm}';
  end
  else
  begin
    UsesClause :=
      '  System.SysUtils, System.Types, System.UITypes, System.Classes,'#13#10 +
      '  System.Variants, FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics,'#13#10 +
      '  FMX.Dialogs;';
    ResourceDirective := '{$R *.fmx}';
  end;

  Result :=
    'unit ' + UnitName + ';'#13#10 +
    #13#10 +
    'interface'#13#10 +
    #13#10 +
    'uses'#13#10 +
    UsesClause + #13#10 +
    #13#10 +
    'type'#13#10 +
    '  ' + FormClass + ' = class(TForm)'#13#10 +
    '  private'#13#10 +
    '    { Private declarations }'#13#10 +
    '  public'#13#10 +
    '    { Public declarations }'#13#10 +
    '  end;'#13#10 +
    #13#10 +
    'var'#13#10 +
    '  ' + FormIdent + ': ' + FormClass + ';'#13#10 +
    #13#10 +
    'implementation'#13#10 +
    #13#10 +
    ResourceDirective + #13#10 +
    #13#10 +
    'end.'#13#10;
end;

{ The IDE will not generate a .dpr for us -- IOTAProjectCreator.NewProjectSource
  returning nil faults inside delphicoreide -- so we emit the same source the
  built-in wizards do. Units are added to the uses clause later by the module
  creator, so the clause here only needs the framework entry point. }
function ProjectSource(const ProgramIdent, Framework, ProjectType: string): string;
var
  UsesClause, Body, AppType: string;
begin
  if SameText(ProjectType, sConsole) then
  begin
    AppType := '{$APPTYPE CONSOLE}'#13#10#13#10;
    UsesClause := '  System.SysUtils;';
    Body :=
      '  try'#13#10 +
      '    { TODO -oUser -cConsole Main : Insert code here }'#13#10 +
      '  except'#13#10 +
      '    on E: Exception do'#13#10 +
      '      Writeln(E.ClassName, '': '', E.Message);'#13#10 +
      '  end;'#13#10;
  end
  else if SameText(Framework, 'VCL') then
  begin
    AppType := '';
    UsesClause := '  Vcl.Forms;';
    Body :=
      '  Application.Initialize;'#13#10 +
      '  Application.MainFormOnTaskbar := True;'#13#10 +
      '  Application.Run;'#13#10;
  end
  else
  begin
    AppType := '';
    UsesClause :=
      '  System.StartUpCopy,'#13#10 +
      '  FMX.Forms;';
    Body :=
      '  Application.Initialize;'#13#10 +
      '  Application.Run;'#13#10;
  end;

  Result :=
    'program ' + ProgramIdent + ';'#13#10 +
    #13#10 +
    AppType +
    'uses'#13#10 +
    UsesClause + #13#10 +
    #13#10 +
    '{$R *.res}'#13#10 +
    #13#10 +
    'begin'#13#10 +
    Body +
    'end.'#13#10;
end;

{ The IDE stores the framework as the exact string 'FMX' or 'VCL' and silently
  treats anything else as a third framework, which later makes it warn that the
  project's own FMX units are incompatible with it. Spellings like 'FireMonkey'
  are the natural thing for a caller to send, so map them rather than storing
  them, and reject what we cannot map instead of creating a broken project. }
function NormalizeFramework(const S: string): string;
begin
  if (S = '') or SameText(S, 'FMX') or SameText(S, 'FireMonkey') then
    Result := sFrameworkTypeFMX
  else if SameText(S, 'VCL') then
    Result := sFrameworkTypeVCL
  else if SameText(S, 'None') or SameText(S, 'Console') then
    Result := ''
  else
    raise Exception.CreateFmt(
      'Unknown framework "%s"; expected FMX, VCL or None', [S]);
end;

{ Tools }

function ModuleResult(const Module: IOTAModule; const UnitName: string): TJSONValue;
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  Obj.AddPair('unitName', UnitName);
  if Module <> nil then
    Obj.AddPair('fileName', Module.FileName);
  Result := Obj;
end;

{ Resolves where a new module should live. A bare unit name is placed next to
  the active project, which is almost always what's wanted and saves the caller
  from having to know the project's directory. }
function ResolveModulePath(const UnitName, RequestedPath: string): string;
var
  Proj: IOTAProject;
begin
  if RequestedPath <> '' then
    Exit(RequestedPath);
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project, so there is nowhere to put the ' +
      'new unit - open a project or pass an explicit filePath');
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(Proj.FileName)) +
    UnitName + '.pas';
end;

function ToolCreateUnit(Params: TJSONObject): TJSONValue;
var
  MS: IOTAModuleServices;
  UnitName, FilePath, Body: string;
  Module: IOTAModule;
begin
  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('ToolsAPI module services unavailable');

  UnitName := Params.GetValue<string>('unitName');
  if not IsValidIdent(UnitName) then
    raise Exception.CreateFmt('"%s" is not a valid unit name', [UnitName]);
  FilePath := ResolveModulePath(UnitName, Params.GetValue<string>('filePath', ''));
  Body := Params.GetValue<string>('body', '');
  if (Body <> '') and not Body.EndsWith(#10) then
    Body := Body + #13#10;
  if Body <> '' then
    Body := Body + #13#10;

  Module := MS.CreateModule(TModuleCreator.Create(UnitName, '', '', FilePath,
    PlainUnitSource(UnitName, Body), False,
    Params.GetValue<Boolean>('show', True)));
  Result := ModuleResult(Module, UnitName);
end;

function ToolCreateForm(Params: TJSONObject): TJSONValue;
var
  MS: IOTAModuleServices;
  UnitName, FormIdent, FilePath, Framework: string;
  Module: IOTAModule;
  Proj: IOTAProject;
begin
  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('ToolsAPI module services unavailable');

  UnitName := Params.GetValue<string>('unitName');
  if not IsValidIdent(UnitName) then
    raise Exception.CreateFmt('"%s" is not a valid unit name', [UnitName]);
  FormIdent := Params.GetValue<string>('formName', '');
  if FormIdent = '' then
    FormIdent := UnitName + 'Form';
  if not IsValidIdent(FormIdent) then
    raise Exception.CreateFmt('"%s" is not a valid form name', [FormIdent]);

  { Default to whatever the active project uses. Guessing FMX here is how a VCL
    project ends up being offered a form unit the IDE then flags as incompatible. }
  Framework := Params.GetValue<string>('framework', '');
  if Framework = '' then
  begin
    Proj := CurrentProject;
    if Proj <> nil then
      Framework := Proj.FrameworkType;
  end;
  Framework := NormalizeFramework(Framework);
  FilePath := ResolveModulePath(UnitName, Params.GetValue<string>('filePath', ''));

  Module := MS.CreateModule(TModuleCreator.Create(UnitName, FormIdent, 'Form',
    FilePath, FormUnitSource(UnitName, FormIdent, Framework), True,
    Params.GetValue<Boolean>('show', True)));
  Result := ModuleResult(Module, UnitName);
end;

function ToolCreateProject(Params: TJSONObject): TJSONValue;
var
  MS: IOTAModuleServices;
  ProjectPath, Framework, ProjectType, Preferred: string;
  PlatformList: TJSONArray;
  Platforms: TArray<string>;
  Module: IOTAModule;
  Proj: IOTAProject;
  Obj: TJSONObject;
  i: Integer;
begin
  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('ToolsAPI module services unavailable');

  ProjectPath := Params.GetValue<string>('filePath');
  if not TPath.IsPathRooted(ProjectPath) then
    raise Exception.Create('filePath must be an absolute path');

  { The creator must be handed the .dpr, not the .dproj: the IDE resolves the
    project-type handler from this extension, and a .dproj finds nothing and
    then dereferences the nil result. Callers naturally say ".dproj", so accept
    either and normalise. The IDE writes the .dproj alongside by itself. }
  ProjectPath := TPath.ChangeExtension(ProjectPath, '.dpr');
  if TFile.Exists(ProjectPath) or
     TFile.Exists(TPath.ChangeExtension(ProjectPath, '.dproj')) then
    raise Exception.CreateFmt('A project already exists at %s',
      [TPath.ChangeExtension(ProjectPath, '.dproj')]);

  { The directory has to exist before the IDE writes into it. }
  ForceDirectories(ExtractFileDir(ProjectPath));

  Framework := NormalizeFramework(Params.GetValue<string>('framework',
    sFrameworkTypeFMX));
  ProjectType := Params.GetValue<string>('projectType', sApplication);
  Preferred := Params.GetValue<string>('preferredPlatform', 'Win32');

  if Params.GetValue('platforms') is TJSONArray then
  begin
    PlatformList := Params.GetValue('platforms') as TJSONArray;
    SetLength(Platforms, PlatformList.Count);
    for i := 0 to PlatformList.Count - 1 do
      Platforms[i] := PlatformList.Items[i].Value;
  end
  else if SameText(Framework, sFrameworkTypeFMX) then
    { FireMonkey's reason for existing is cross-platform, so an FMX project
      that only targets Windows is almost never what was meant. }
    Platforms := ['Win32', 'Win64', 'Android', 'Android64', 'iOSDevice64']
  else
    Platforms := ['Win32', 'Win64'];

  Module := MS.CreateModule(TProjectCreator.Create(ProjectPath, Framework,
    ProjectType, Preferred, Platforms));
  if not Supports(Module, IOTAProject, Proj) then
    raise Exception.Create('The IDE did not return a project for the new module');

  Obj := TJSONObject.Create;
  Obj.AddPair('fileName', Proj.FileName);
  Obj.AddPair('frameworkType', Proj.FrameworkType);
  Obj.AddPair('currentPlatform', Proj.CurrentPlatform);
  Result := Obj;
end;

procedure RegisterCreateTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolCreateUnit;    RegisterFn('createUnit', F);
  F := ToolCreateForm;    RegisterFn('createForm', F);
  F := ToolCreateProject; RegisterFn('createProject', F);
end;

end.
