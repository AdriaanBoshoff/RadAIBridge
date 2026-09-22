unit RadAiBridge.Dispatcher;

{ Wires all tool modules into one RPC server instance. All ToolsAPI/VCL/FMX
  calls made by tool handlers must run on the IDE's main thread, so every
  handler is wrapped to run there via RadAiBridge.MainThread. }

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  RadAiBridge.Json.Rpc, RadAiBridge.MainThread;

function CreateAndStartServer: TRpcServer;

implementation

uses
  RadAiBridge.Tools.Files,
  RadAiBridge.Tools.Project,
  RadAiBridge.Tools.Build,
  RadAiBridge.Tools.Debug,
  RadAiBridge.Tools.Capture,
  RadAiBridge.Tools.Design,
  RadAiBridge.Tools.Create,
  RadAiBridge.Tools.Source;

function SyncWrap(const Inner: TFunc<TJSONObject, TJSONValue>): TFunc<TJSONObject, TJSONValue>;
begin
  Result :=
    function(Params: TJSONObject): TJSONValue
    var
      ResultVal: TJSONValue;
      ErrMsg: string;
      HasError: Boolean;
    begin
      ResultVal := nil;
      HasError := False;
      ErrMsg := '';
      RunOnMainThread(
        procedure
        begin
          try
            ResultVal := Inner(Params);
          except
            on E: Exception do
            begin
              HasError := True;
              ErrMsg := E.Message;
            end;
          end;
        end);
      if HasError then
        raise Exception.Create(ErrMsg);
      Result := ResultVal;
    end;
end;

{ Anything that talks to ToolsAPI has to run on the IDE's main thread, so it
  goes through SyncWrap. A tool that would hold that thread for a long time -
  a build - registers raw instead and marshals only the parts that need it,
  otherwise the IDE appears frozen for the whole call. }

function CreateAndStartServer: TRpcServer;
var
  Server: TRpcServer;
  RegisterFn, RegisterRawFn: TProc<string, TFunc<TJSONObject, TJSONValue>>;
begin
  Server := TRpcServer.Create;

  RegisterFn :=
    procedure(Name: string; Func: TFunc<TJSONObject, TJSONValue>)
    begin
      Server.RegisterMethod(Name, SyncWrap(Func));
    end;

  RegisterRawFn :=
    procedure(Name: string; Func: TFunc<TJSONObject, TJSONValue>)
    begin
      Server.RegisterMethod(Name, Func);
    end;

  Server.RegisterMethod('ping',
    function(Params: TJSONObject): TJSONValue
    begin
      Result := TJSONBool.Create(True);
    end);

  RegisterFileTools(RegisterFn);
  RegisterProjectTools(RegisterFn);
  RegisterBuildTools(RegisterRawFn);
  RegisterDebugTools(RegisterFn);
  { Raw on purpose: capturing needs no main thread, so it is the one tool that
    still answers while a modal dialog owns the IDE. See the unit header. }
  RegisterCaptureTools(RegisterRawFn);
  RegisterDesignTools(RegisterFn);
  RegisterCreateTools(RegisterFn);
  RegisterSourceTools(RegisterFn);

  Server.Start;
  Result := Server;
end;

end.
