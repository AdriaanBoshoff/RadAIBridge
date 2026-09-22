unit RadAiBridge.Tools.Project;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.Variants,
  ToolsAPI, RadAiBridge.Ide.Utils;

procedure RegisterProjectTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

function ToolGetProjectInfo(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  Obj, Entry: TJSONObject;
  Files, Platforms: TJSONArray;
  ModuleInfo: IOTAModuleInfo;
  i: Integer;
  FilePathParam, PlatformName: string;
  MS: IOTAModuleServices;
  Module: IOTAModule;
begin
  FilePathParam := Params.GetValue<string>('projectFile', '');
  if FilePathParam <> '' then
  begin
    MS := ModuleServices;
    Module := nil;
    if MS <> nil then
      Module := MS.FindModule(FilePathParam);
    if not Supports(Module, IOTAProject, Proj) then
      raise Exception.CreateFmt('Project not open: %s', [FilePathParam]);
  end
  else
    Proj := CurrentProject;

  if Proj = nil then
    raise Exception.Create('No active project');

  Obj := TJSONObject.Create;
  Obj.AddPair('fileName', Proj.FileName);
  Obj.AddPair('projectType', Proj.ProjectType);
  Obj.AddPair('frameworkType', Proj.FrameworkType);
  Obj.AddPair('currentPlatform', Proj.CurrentPlatform);
  Obj.AddPair('currentConfiguration', Proj.CurrentConfiguration);

  Platforms := TJSONArray.Create;
  for PlatformName in Proj.SupportedPlatforms do
    Platforms.Add(PlatformName);
  Obj.AddPair('supportedPlatforms', Platforms);

  { GetModuleFileCount describes the project module's own files (the .dpr), not
    the project's contents. The units and forms that make up the project come
    from GetModuleCount. Entries with no filename are bookkeeping rows rather
    than real source files, so they're skipped; the form name is worth carrying
    because it's what the designer tools address. }
  Files := TJSONArray.Create;
  for i := 0 to Proj.GetModuleCount - 1 do
  begin
    ModuleInfo := Proj.GetModule(i);
    if (ModuleInfo = nil) or (ModuleInfo.FileName = '') then
      Continue;
    Entry := TJSONObject.Create;
    Entry.AddPair('fileName', ModuleInfo.FileName);
    if ModuleInfo.FormName <> '' then
      Entry.AddPair('formName', ModuleInfo.FormName);
    Files.Add(Entry);
  end;
  Obj.AddPair('files', Files);

  Result := Obj;
end;

function ToolAddFileToProject(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  FilePath: string;
  IsUnitOrForm: Boolean;
begin
  FilePath := Params.GetValue<string>('filePath');
  IsUnitOrForm := Params.GetValue<Boolean>('isUnitOrForm', True);
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  if not TFile.Exists(FilePath) then
    raise Exception.CreateFmt('File does not exist on disk: %s', [FilePath]);
  Proj.AddFile(FilePath, IsUnitOrForm);
  Result := TJSONBool.Create(True);
end;

function ToolRemoveFileFromProject(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  FilePath: string;
  i: Integer;
begin
  FilePath := Params.GetValue<string>('filePath');
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  { Check against the project's modules, not the project module's own files -
    the latter only ever contains the .dpr, so this rejected every real unit. }
  for i := 0 to Proj.GetModuleCount - 1 do
    if SameFileName(Proj.GetModule(i).FileName, FilePath) then
    begin
      Proj.RemoveFile(FilePath);
      Result := TJSONBool.Create(True);
      Exit;
    end;
  raise Exception.CreateFmt('File is not part of the project: %s', [FilePath]);
end;

function ToolOpenProject(Params: TJSONObject): TJSONValue;
var
  FilePath: string;
  MS: IOTAModuleServices;
  Module: IOTAModule;
begin
  FilePath := Params.GetValue<string>('filePath');
  MS := ModuleServices;
  if MS = nil then
    raise Exception.Create('Module services unavailable');
  Module := MS.OpenModule(FilePath);
  Result := TJSONBool.Create(Module <> nil);
end;

{ Retargeting a project - Win32 to Android, Debug to Release - otherwise means
  clicking through the Project Manager. Both are plain properties on IOTAProject,
  and setting them here is equivalent to picking them in the target combo. }
function ToolSetProjectPlatform(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  PlatformName, ConfigName, Supported: string;
  Known: Boolean;
  Obj: TJSONObject;
begin
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');

  PlatformName := Params.GetValue<string>('platform', '');
  ConfigName := Params.GetValue<string>('config', '');

  if PlatformName <> '' then
  begin
    { Reject an unsupported platform up front - assigning one silently leaves
      the project on its old target, which is a confusing way to fail. }
    Known := False;
    for Supported in Proj.SupportedPlatforms do
      if SameText(Supported, PlatformName) then
      begin
        PlatformName := Supported;
        Known := True;
        Break;
      end;
    if not Known then
      raise Exception.CreateFmt('Platform "%s" is not supported by this project. ' +
        'Supported: %s', [PlatformName, string.Join(', ', Proj.SupportedPlatforms)]);
    Proj.CurrentPlatform := PlatformName;
  end;

  if ConfigName <> '' then
    Proj.CurrentConfiguration := ConfigName;

  Obj := TJSONObject.Create;
  Obj.AddPair('currentPlatform', Proj.CurrentPlatform);
  Obj.AddPair('currentConfiguration', Proj.CurrentConfiguration);
  Result := Obj;
end;

{ Project settings live on build configurations, not on IOTAProjectOptions -
  the same option can hold different values for Debug vs Release and for each
  platform, which is exactly how the Project Options dialog presents them.
  Reading them off IOTAProjectOptions.Values mostly returns nothing, so
  everything here resolves a configuration first. }
function ResolveBuildConfig(const Proj: IOTAProject;
  const ConfigName, PlatformName: string): IOTABuildConfiguration;
var
  Configs: IOTAProjectOptionsConfigurations;
  Names: string;
  i: Integer;
begin
  Result := nil;
  if not Supports(Proj.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) then
    raise Exception.Create('This project does not expose build configurations');

  if ConfigName = '' then
    Result := Configs.ActiveConfiguration
  else
  begin
    Names := '';
    for i := 0 to Configs.ConfigurationCount - 1 do
    begin
      if SameText(Configs.Configurations[i].Name, ConfigName) then
      begin
        Result := Configs.Configurations[i];
        Break;
      end;
      if Names <> '' then
        Names := Names + ', ';
      Names := Names + Configs.Configurations[i].Name;
    end;
    if Result = nil then
      raise Exception.CreateFmt('No such build configuration: "%s". Available: %s',
        [ConfigName, Names]);
  end;

  if Result = nil then
    raise Exception.Create('Could not resolve a build configuration');

  { A platform-specific child holds the overrides for that target; without one
    you read and write the configuration's cross-platform values. }
  if PlatformName <> '' then
  begin
    Result := Result.PlatformConfiguration[PlatformName];
    if Result = nil then
      raise Exception.CreateFmt('Configuration has no settings for platform "%s"',
        [PlatformName]);
  end;
end;

function ToolGetProjectOption(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  Config: IOTABuildConfiguration;
  OptionName: string;
begin
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  Config := ResolveBuildConfig(Proj, Params.GetValue<string>('config', ''),
    Params.GetValue<string>('platform', ''));
  OptionName := Params.GetValue<string>('optionName');
  { GetValue walks up to parent configurations, so this returns the value that
    would actually be used for a build, inherited or not. }
  Result := TJSONString.Create(Config.Value[OptionName]);
end;

function ToolSetProjectOption(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  Config: IOTABuildConfiguration;
begin
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  Config := ResolveBuildConfig(Proj, Params.GetValue<string>('config', ''),
    Params.GetValue<string>('platform', ''));
  Config.Value[Params.GetValue<string>('optionName')] :=
    Params.GetValue<string>('value');
  Proj.MarkModified;
  Result := TJSONBool.Create(True);
end;

{ Option names are obscure and undiscoverable otherwise - this is the only
  practical way to find out what a project actually has set. }
function ToolListProjectOptions(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  Config: IOTABuildConfiguration;
  Obj: TJSONObject;
  PropName: string;
  i: Integer;
begin
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  Config := ResolveBuildConfig(Proj, Params.GetValue<string>('config', ''),
    Params.GetValue<string>('platform', ''));

  Obj := TJSONObject.Create;
  Obj.AddPair('configuration', Config.Name);
  Obj.AddPair('platform', Config.Platform);
  for i := 0 to Config.PropertyCount - 1 do
  begin
    PropName := Config.Properties[i];
    Obj.AddPair(PropName, Config.Value[PropName]);
  end;
  Result := Obj;
end;

function ToolListBuildConfigurations(Params: TJSONObject): TJSONValue;
var
  Proj: IOTAProject;
  Configs: IOTAProjectOptionsConfigurations;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Platforms: TJSONArray;
  PlatformName: string;
  i: Integer;
begin
  Proj := CurrentProject;
  if Proj = nil then
    raise Exception.Create('No active project');
  if not Supports(Proj.ProjectOptions, IOTAProjectOptionsConfigurations, Configs) then
    raise Exception.Create('This project does not expose build configurations');

  Arr := TJSONArray.Create;
  for i := 0 to Configs.ConfigurationCount - 1 do
  begin
    Entry := TJSONObject.Create;
    Entry.AddPair('name', Configs.Configurations[i].Name);
    Entry.AddPair('active', TJSONBool.Create(
      SameText(Configs.Configurations[i].Name, Configs.ActiveConfigurationName)));
    Platforms := TJSONArray.Create;
    for PlatformName in Configs.Configurations[i].Platforms do
      Platforms.Add(PlatformName);
    Entry.AddPair('platforms', Platforms);
    Arr.Add(Entry);
  end;
  Result := Arr;
end;

procedure RegisterProjectTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolGetProjectInfo;         RegisterFn('getProjectInfo', F);
  F := ToolAddFileToProject;       RegisterFn('addFileToProject', F);
  F := ToolRemoveFileFromProject;  RegisterFn('removeFileFromProject', F);
  F := ToolOpenProject;            RegisterFn('openProject', F);
  F := ToolSetProjectPlatform;     RegisterFn('setProjectPlatform', F);
  F := ToolGetProjectOption;       RegisterFn('getProjectOption', F);
  F := ToolSetProjectOption;       RegisterFn('setProjectOption', F);
  F := ToolListProjectOptions;     RegisterFn('listProjectOptions', F);
  F := ToolListBuildConfigurations; RegisterFn('listBuildConfigurations', F);
end;

end.
