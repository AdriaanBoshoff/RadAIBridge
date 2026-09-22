unit RadAiBridge.Json.Rpc;

{ Minimal local-only JSON-RPC 2.0 server over a raw TCP loopback socket.
  Line-delimited: one JSON object per line, UTF-8, terminated by #10.
  No Indy/other package dependency - just Winsock2, to avoid version-suffix
  coupling with the host IDE's bundled component packages. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  System.Generics.Collections, Winapi.Windows, Winapi.Winsock2;

type
  TRpcMethodFunc = TFunc<TJSONObject, TJSONValue>;

  TRpcServer = class(TThread)
  private
    FListenSocket: TSocket;
    FPort: Word;
    FMethods: TDictionary<string, TRpcMethodFunc>;
    FLock: TCriticalSection;
    FBoundEvent: TEvent;
    FActiveHandlers: Integer;
    procedure HandleClient(ClientSocket: TSocket);
    procedure SpawnClientHandler(ClientSocket: TSocket);
    function DispatchRequest(const RequestLine: string): string;
    function RecvLine(Socket: TSocket; var Line: string): Boolean;
    procedure SendLine(Socket: TSocket; const Line: string);
    procedure CloseListenSocket;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterMethod(const Name: string; Func: TRpcMethodFunc);
    function WaitUntilBound(TimeoutMs: Cardinal): Boolean;
    property Port: Word read FPort;
  end;

implementation

{ TRpcServer }

constructor TRpcServer.Create;
var
  WSAData: TWSAData;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FMethods := TDictionary<string, TRpcMethodFunc>.Create;
  FLock := TCriticalSection.Create;
  FBoundEvent := TEvent.Create(nil, True, False, '');
  WSAStartup($0202, WSAData);
  FListenSocket := INVALID_SOCKET;
end;

{ Closing the listening socket is what actually wakes Execute: accept() blocks
  until a connection arrives or the socket is closed, and Terminate alone only
  sets a flag. Doing this from TerminatedSet - which Terminate calls - means a
  caller can Terminate/WaitFor without deadlocking.

  Before this, Destroy's WaitFor waited on a thread parked in accept(), and the
  socket it was waiting on was only closed further down in Destroy, which could
  not be reached. That hung the IDE's shutdown indefinitely: bds.exe stayed
  alive with no main window, still holding the port. }
procedure TRpcServer.CloseListenSocket;
var
  Sock: TSocket;
begin
  Sock := TSocket(TInterlocked.Exchange(NativeInt(FListenSocket),
    NativeInt(INVALID_SOCKET)));
  if Sock <> INVALID_SOCKET then
    closesocket(Sock);
end;

procedure TRpcServer.TerminatedSet;
begin
  inherited;
  CloseListenSocket;
end;

destructor TRpcServer.Destroy;
const
  HandlerDrainMs = 3000;
var
  Waited: Integer;
begin
  CloseListenSocket;

  { Client handler threads outlive the accept loop. Give them a bounded moment
    to finish before the dictionary and lock they use go away. Bounded because
    a handler parked in a tool call must not hold up closing the IDE. }
  Waited := 0;
  while (FActiveHandlers > 0) and (Waited < HandlerDrainMs) do
  begin
    Sleep(25);
    Inc(Waited, 25);
  end;

  WSACleanup;
  FMethods.Free;
  FLock.Free;
  FBoundEvent.Free;
  inherited;
end;

procedure TRpcServer.RegisterMethod(const Name: string; Func: TRpcMethodFunc);
begin
  FLock.Enter;
  try
    FMethods.AddOrSetValue(Name, Func);
  finally
    FLock.Leave;
  end;
end;

function TRpcServer.WaitUntilBound(TimeoutMs: Cardinal): Boolean;
begin
  Result := FBoundEvent.WaitFor(TimeoutMs) = wrSignaled;
end;

procedure TRpcServer.Execute;
var
  Addr: TSockAddrIn;
  AddrLen: Integer;
  ClientSocket: TSocket;
begin
  FListenSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FListenSocket = INVALID_SOCKET then
  begin
    FBoundEvent.SetEvent;
    Exit;
  end;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_addr.S_addr := inet_addr('127.0.0.1');
  Addr.sin_port := 0; // let the OS pick a free port

  if bind(FListenSocket, TSockAddr(Addr), SizeOf(Addr)) = SOCKET_ERROR then
  begin
    FBoundEvent.SetEvent;
    Exit;
  end;

  AddrLen := SizeOf(Addr);
  getsockname(FListenSocket, TSockAddr(Addr), AddrLen);
  FPort := ntohs(Addr.sin_port);

  if listen(FListenSocket, 4) = SOCKET_ERROR then
  begin
    FBoundEvent.SetEvent;
    Exit;
  end;

  FBoundEvent.SetEvent;

  while not Terminated do
  begin
    ClientSocket := accept(FListenSocket, nil, nil);

    if Terminated then
    begin
      if ClientSocket <> INVALID_SOCKET then
        closesocket(ClientSocket);
      Break;
    end;

    if ClientSocket = INVALID_SOCKET then
    begin
      { accept failed. A closed listening socket means we are shutting down;
        anything else is transient, and backing off beats spinning on it. }
      if FListenSocket = INVALID_SOCKET then
        Break;
      Sleep(50);
      Continue;
    end;

    SpawnClientHandler(ClientSocket);
  end;
end;

{ Each client gets its own thread.

  Two reasons, both learned the hard way:

  Serving clients inline from the accept loop meant one call could block every
  other one. That defeated the point of registering captureScreenshot raw - an
  agent whose call was stuck could not take a screenshot to find out *why*,
  because the stuck call still owned the server.

  And an exception escaping HandleClient unwound Execute, so the server thread
  died while the IDE carried on running. The symptom is nasty: no error, no
  dialog, just ECONNREFUSED on every later call and no way back short of
  restarting the IDE. Serving a client must never be able to take down the
  listener, so the handler swallows everything. }
procedure TRpcServer.SpawnClientHandler(ClientSocket: TSocket);
begin
  TInterlocked.Increment(FActiveHandlers);
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try
          HandleClient(ClientSocket);
        except
          { Deliberately swallowed - see above. DispatchRequest already turns
            tool failures into proper JSON-RPC error replies, so anything
            reaching here is a transport-level failure affecting only this
            one client. }
          on E: Exception do
            ;
        end;
      finally
        TInterlocked.Decrement(FActiveHandlers);
      end;
    end).Start;
end;

function TRpcServer.RecvLine(Socket: TSocket; var Line: string): Boolean;
var
  Buf: array[0..1] of AnsiChar;
  Received: Integer;
  Bytes: TBytes;
begin
  SetLength(Bytes, 0);
  while True do
  begin
    Received := recv(Socket, Buf, 1, 0);
    if Received <= 0 then
      Exit(False);
    if Buf[0] = #10 then
      Break;
    if Buf[0] <> #13 then
    begin
      SetLength(Bytes, Length(Bytes) + 1);
      Bytes[High(Bytes)] := Byte(Buf[0]);
    end;
  end;
  Line := TEncoding.UTF8.GetString(Bytes);
  Result := True;
end;

procedure TRpcServer.SendLine(Socket: TSocket; const Line: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Line + #10);
  send(Socket, Bytes[0], Length(Bytes), 0);
end;

{ Reads whatever the peer still has in flight (bounded, so a chatty or wedged
  client cannot pin this thread) and then closes. }
procedure DrainAndClose(Socket: TSocket);
const
  MaxDrainPasses = 64;
var
  Buf: array[0..1023] of AnsiChar;
  Passes: Integer;
  Timeout: Integer;
begin
  try
    { Without a receive timeout, draining a client that has gone quiet without
      closing would block this thread - and the accept loop runs HandleClient
      inline, so that would wedge the whole server. }
    Timeout := 250;
    setsockopt(Socket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
    for Passes := 1 to MaxDrainPasses do
      if recv(Socket, Buf, SizeOf(Buf), 0) <= 0 then
        Break;
  finally
    closesocket(Socket);
  end;
end;

procedure TRpcServer.HandleClient(ClientSocket: TSocket);
var
  Line, Response: string;
begin
  try
    while (not Terminated) and RecvLine(ClientSocket, Line) do
    begin
      if Trim(Line) = '' then
        Continue;
      Response := DispatchRequest(Line);
      SendLine(ClientSocket, Response);
    end;
  finally
    { Graceful close. Calling closesocket outright while anything is still
      unread - or while the peer's FIN has not been consumed - makes Winsock
      send an RST, which reaches the client as ECONNRESET *after* it has
      already received a perfectly good reply. That turns every successful
      call into an apparent transport failure.

      Sending our own FIN first and draining whatever is left lets the close
      complete normally. }
    shutdown(ClientSocket, SD_SEND);
    DrainAndClose(ClientSocket);
  end;
end;

function TRpcServer.DispatchRequest(const RequestLine: string): string;
var
  Req, Resp, ErrObj, ParamsObj: TJSONObject;
  ReqVal, IdVal, ResultVal: TJSONValue;
  MethodName: string;
  Func: TRpcMethodFunc;
begin
  Resp := TJSONObject.Create;
  IdVal := nil;
  try
    try
      ReqVal := TJSONObject.ParseJSONValue(RequestLine);
      try
        if not (ReqVal is TJSONObject) then
          raise Exception.Create('Request must be a JSON object');
        Req := TJSONObject(ReqVal);

        if Req.TryGetValue<TJSONValue>('id', IdVal) then
          Resp.AddPair('id', IdVal.Clone as TJSONValue)
        else
          Resp.AddPair('id', TJSONNull.Create);

        MethodName := Req.GetValue<string>('method', '');
        if not Req.TryGetValue<TJSONObject>('params', ParamsObj) then
          ParamsObj := TJSONObject.Create;

        FLock.Enter;
        try
          if not FMethods.TryGetValue(MethodName, Func) then
            raise Exception.CreateFmt('Unknown method: %s', [MethodName]);
        finally
          FLock.Leave;
        end;

        ResultVal := Func(ParamsObj);
        if ResultVal = nil then
          ResultVal := TJSONNull.Create;
        Resp.AddPair('result', ResultVal);
      finally
        ReqVal.Free;
      end;
    except
      on E: Exception do
      begin
        if Resp.GetValue('id') = nil then
          Resp.AddPair('id', TJSONNull.Create);
        ErrObj := TJSONObject.Create;
        ErrObj.AddPair('message', E.Message);
        Resp.AddPair('error', ErrObj);
      end;
    end;
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

end.
