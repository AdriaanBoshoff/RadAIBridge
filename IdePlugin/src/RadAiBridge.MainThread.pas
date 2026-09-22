unit RadAiBridge.MainThread;

{ Runs a piece of work on the IDE's main thread and waits for the result.

  This deliberately does not use TThread.Synchronize. Synchronize runs the work
  from inside the RTL's CheckSynchronize, and some IDE operations - creating a
  project is the one that exposed it - do UI work of their own that does not
  survive being re-entered from there: the call either raises "Unexpected wait
  result" while having actually succeeded, or wedges.

  Posting a message to our own window instead means the work runs from whatever
  message loop the IDE is currently pumping, which is the context the IDE
  expects.

  It does NOT rescue us from modal dialogs, despite an earlier comment here
  claiming it did. Measured: while any IDE modal is up, every call through here
  times out. The modal runs its own loop and our posted message is not
  dispatched to the target window from it. The only tool that keeps working is
  captureScreenshot with target "ide", which is why that one deliberately
  avoids this unit.

  The wait is bounded. A blocked main thread now fails one call with a message
  that says what is probably happening, instead of hanging the caller forever. }

interface

uses
  System.SysUtils;

const
  { Long enough for slow designer and project operations, short enough that a
    stuck IDE reports itself rather than hanging the client. }
  DefaultMainThreadTimeoutMs = 120000;

procedure RunOnMainThread(const Proc: TProc;
  TimeoutMs: Cardinal = DefaultMainThreadTimeoutMs);

implementation

uses
  Winapi.Windows, Winapi.Messages, System.Classes, System.SyncObjs;

const
  WM_RUN_ON_MAIN = WM_APP + 4711;

type
  { Shared between the caller and the main thread. Refcounted because a call
    that times out must not leave the main thread writing into freed memory
    when it eventually gets round to running the work. }
  TCallBox = class
  private
    FRefCount: Integer;
  public
    Proc: TProc;
    Done: TEvent;
    ErrMsg: string;
    HasError: Boolean;
    constructor Create(const AProc: TProc);
    destructor Destroy; override;
    procedure AddRef;
    procedure Release;
  end;

  { AllocateHWnd wants a method pointer, so the window procedure needs an
    owner object even though it holds no state of its own. }
  TWndHost = class
  public
    procedure WndProc(var Msg: TMessage);
  end;

var
  GWnd: HWND = 0;
  GHost: TWndHost = nil;

constructor TCallBox.Create(const AProc: TProc);
begin
  inherited Create;
  FRefCount := 1;
  Proc := AProc;
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TCallBox.Destroy;
begin
  Done.Free;
  inherited;
end;

procedure TCallBox.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;

procedure TCallBox.Release;
begin
  if TInterlocked.Decrement(FRefCount) = 0 then
    Free;
end;

procedure TWndHost.WndProc(var Msg: TMessage);
var
  Box: TCallBox;
begin
  if Msg.Msg = WM_RUN_ON_MAIN then
  begin
    Box := TCallBox(Msg.LParam);
    try
      try
        Box.Proc();
      except
        on E: Exception do
        begin
          Box.HasError := True;
          Box.ErrMsg := E.Message;
        end;
      end;
      Box.Done.SetEvent;
    finally
      Box.Release;
    end;
    Msg.Result := 1;
  end
  else
    Msg.Result := DefWindowProc(GWnd, Msg.Msg, Msg.WParam, Msg.LParam);
end;

procedure RunOnMainThread(const Proc: TProc; TimeoutMs: Cardinal);
var
  Box: TCallBox;
  Wait: TWaitResult;
begin
  { Already where we need to be - just run it, so a tool calling another tool
    does not deadlock on itself. }
  if GetCurrentThreadId = MainThreadID then
  begin
    Proc();
    Exit;
  end;

  if GWnd = 0 then
    raise Exception.Create('RadAiBridge main-thread dispatcher is not running');

  Box := TCallBox.Create(Proc);
  try
    Box.AddRef; { the main thread's reference }
    if not PostMessage(GWnd, WM_RUN_ON_MAIN, 0, LPARAM(Box)) then
    begin
      Box.Release;
      RaiseLastOSError;
    end;

    { wrIOCompletion just means the wait was interrupted; it says nothing about
      the work, so keep waiting. }
    repeat
      Wait := Box.Done.WaitFor(TimeoutMs);
    until Wait <> wrIOCompletion;

    if Wait <> wrSignaled then
      raise Exception.CreateFmt(
        'The IDE main thread did not respond within %d ms. It is most likely ' +
        'showing a modal dialog that needs to be dismissed.', [TimeoutMs]);

    if Box.HasError then
      raise Exception.Create(Box.ErrMsg);
  finally
    Box.Release;
  end;
end;

initialization
  { The package is loaded on the IDE's main thread, so the window belongs to it
    and messages posted here are dispatched by the IDE's own loop. }
  if GetCurrentThreadId = MainThreadID then
  begin
    GHost := TWndHost.Create;
    GWnd := AllocateHWnd(GHost.WndProc);
  end;

finalization
  if GWnd <> 0 then
  begin
    DeallocateHWnd(GWnd);
    GWnd := 0;
  end;
  FreeAndNil(GHost);

end.
