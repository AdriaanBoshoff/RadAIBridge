unit RadAiBridge.Wizard;

{ Package entry point. Registers a silent IOTAWizard purely so the package
  has a lifecycle hook: on IDE load it starts the JSON-RPC bridge server and
  publishes the port and process id to %APPDATA%\RadAiBridge\bridge.json so the external
  MCP server (Node process, launched by Claude Code) can find and connect to
  it. On IDE unload it stops the server and removes the discovery file. }

interface

procedure Register;

implementation

uses
  System.SysUtils, System.IOUtils, System.JSON, Winapi.Windows,
  ToolsAPI, RadAiBridge.Json.Rpc, RadAiBridge.Dispatcher;

type
  TRadAiBridgeWizard = class(TNotifierObject, IOTAWizard)
  private
    FServer: TRpcServer;
    function DiscoveryFilePath: string;
    procedure WriteDiscoveryFile;
    procedure DeleteDiscoveryFile;
  public
    constructor Create;
    destructor Destroy; override;
    // IOTAWizard
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
  end;

var
  WizardIndex: Integer = -1;

{ TRadAiBridgeWizard }

constructor TRadAiBridgeWizard.Create;
begin
  inherited Create;
  FServer := CreateAndStartServer;
  FServer.WaitUntilBound(5000);
  WriteDiscoveryFile;
end;

destructor TRadAiBridgeWizard.Destroy;
begin
  DeleteDiscoveryFile;
  if FServer <> nil then
  begin
    FServer.Terminate;
    FServer.WaitFor;
    FServer.Free;
  end;
  inherited;
end;

function TRadAiBridgeWizard.DiscoveryFilePath: string;
begin
  Result := TPath.Combine(TPath.Combine(GetEnvironmentVariable('APPDATA'), 'RadAiBridge'), 'bridge.json');
end;

procedure TRadAiBridgeWizard.WriteDiscoveryFile;
var
  Obj: TJSONObject;
  Dir: string;
begin
  Dir := TPath.GetDirectoryName(DiscoveryFilePath);
  if not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);

  Obj := TJSONObject.Create;
  try
    Obj.AddPair('port', TJSONNumber.Create(FServer.Port));
    Obj.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
    Obj.AddPair('version', '1');
    TFile.WriteAllText(DiscoveryFilePath, Obj.ToJSON, TEncoding.UTF8);
  finally
    Obj.Free;
  end;
end;

{ Only remove the file if it still describes *this* IDE. The path is shared by
  every running instance, so an instance shutting down after another has started
  would otherwise delete the newcomer's entry and leave the bridge undiscoverable
  while it is in fact running - which is exactly what a restart looks like when
  the old process is slow to exit. }
procedure TRadAiBridgeWizard.DeleteDiscoveryFile;
var
  Obj: TJSONObject;
begin
  if not TFile.Exists(DiscoveryFilePath) then
    Exit;
  try
    Obj := TJSONObject.ParseJSONValue(
      TFile.ReadAllText(DiscoveryFilePath, TEncoding.UTF8)) as TJSONObject;
    if Obj <> nil then
    try
      if Obj.GetValue<Integer>('pid', 0) <> Integer(GetCurrentProcessId) then
        Exit;
    finally
      Obj.Free;
    end;
    TFile.Delete(DiscoveryFilePath);
  except
    { A corrupt or unreadable discovery file is not worth failing shutdown over. }
  end;
end;

function TRadAiBridgeWizard.GetIDString: string;
begin
  Result := 'com.radaibridge.wizard';
end;

function TRadAiBridgeWizard.GetName: string;
begin
  Result := 'RAD AI Bridge';
end;

function TRadAiBridgeWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TRadAiBridgeWizard.Execute;
begin
  // No menu entry; this wizard only exists for its lifecycle hooks.
end;

procedure Register;
begin
  WizardIndex := (BorlandIDEServices as IOTAWizardServices).AddWizard(TRadAiBridgeWizard.Create);
end;

procedure RemoveWizard;
begin
  if WizardIndex >= 0 then
  begin
    (BorlandIDEServices as IOTAWizardServices).RemoveWizard(WizardIndex);
    WizardIndex := -1;
  end;
end;

initialization

finalization
  RemoveWizard;

end.
