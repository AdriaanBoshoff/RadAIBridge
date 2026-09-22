unit RadAiBridge.Tools.Capture;

{ Visual feedback.

  Every other tool here describes the application structurally - a component
  tree, a property value, a compiler message. None of that tells an agent
  whether the UI actually *looks* right: controls overlapping, text clipped,
  a layout that collapses at a different window size, a form that is simply
  blank because a runtime exception ate the constructor.

  This captures the real pixels, so "it compiles and runs" stops being the
  ceiling on what an agent can verify about its own work.

  PrintWindow is used rather than a screen grab so the target does not have to
  be visible, unobscured or focused. PW_RENDERFULLCONTENT is what makes it work
  for windows that render through DirectX/GPU compositing, which is how FMX
  draws - without it an FMX window comes back black.

  This unit is registered RAW - it is not wrapped onto the IDE main thread like
  the other tool modules. That is the whole point of it being useful during a
  modal: when a dialog has the main thread, every marshalled tool times out, and
  an agent that cannot see the screen has no way to find out what is blocking
  it. Capturing is pure Win32 - EnumWindows, PrintWindow, GDI, WIC - and needs
  no main thread and no ToolsAPI, so target "ide" still answers.

  The one piece that DOES need ToolsAPI is finding the debugged program's PID,
  so target "app" marshals just that lookup and will time out during a modal.
  That asymmetry is intentional and documented. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.NetEncoding,
  Winapi.Windows, Winapi.ActiveX, Vcl.Graphics, ToolsAPI,
  RadAiBridge.Ide.Utils, RadAiBridge.MainThread;

procedure RegisterCaptureTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);

implementation

const
  { Neither the flag nor the function is declared in Winapi.Windows. }
  PW_RENDERFULLCONTENT = $00000002;

function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external user32 name 'PrintWindow';

type
  TWindowSearch = record
    TargetPid: DWORD;
    TitleFilter: string;
    Found: HWND;
    FoundArea: Int64;
  end;
  PWindowSearch = ^TWindowSearch;

function EnumProc(Wnd: HWND; LParam: LPARAM): BOOL; stdcall;
var
  Search: PWindowSearch;
  WndPid: DWORD;
  Buf: array[0..511] of Char;
  Title: string;
  R: TRect;
  Area: Int64;
begin
  Result := True;
  Search := PWindowSearch(LParam);

  if not IsWindowVisible(Wnd) then
    Exit;
  GetWindowThreadProcessId(Wnd, WndPid);
  if WndPid <> Search.TargetPid then
    Exit;
  { Deliberately NOT filtering out owned windows. Both VCL and FMX give the
    application a hidden owner window, so the real main form IS owned -
    excluding owned windows finds nothing and looks like the app never opened
    one. Picking the largest visible window is what separates the form from
    the hidden helpers. }

  FillChar(Buf, SizeOf(Buf), 0);
  GetWindowText(Wnd, Buf, Length(Buf));
  Title := Buf;

  if (Search.TitleFilter <> '') and
     not Title.ToLower.Contains(Search.TitleFilter.ToLower) then
    Exit;

  if not GetWindowRect(Wnd, R) then
    Exit;
  Area := Int64(R.Width) * Int64(R.Height);
  if Area <= 0 then
    Exit;

  { A process can own several top-level windows - splash screens, hidden
    helpers. The largest visible one is the main window in practice. }
  if Area > Search.FoundArea then
  begin
    Search.FoundArea := Area;
    Search.Found := Wnd;
  end;
end;

function FindMainWindowOfProcess(Pid: DWORD; const TitleFilter: string): HWND;
var
  Search: TWindowSearch;
begin
  Search.TargetPid := Pid;
  Search.TitleFilter := TitleFilter;
  Search.Found := 0;
  Search.FoundArea := 0;
  EnumWindows(@EnumProc, LPARAM(@Search));
  Result := Search.Found;
end;

{ Returns a PNG as base64. Falls back from PrintWindow to BitBlt, because
  PrintWindow can come back blank for some GPU-composited windows and a screen
  grab of the same rectangle is better than nothing. }
function CaptureWindowToPngBase64(Wnd: HWND; out Width, Height: Integer): string;
var
  R: TRect;
  Bmp: TBitmap;
  Png: TWICImage;
  Stream: TMemoryStream;
  ScreenDC: HDC;
  Ok: Boolean;
  ComHr: HRESULT;
begin
  if (Wnd = 0) or not IsWindow(Wnd) then
    raise Exception.Create('The window no longer exists');
  if not GetWindowRect(Wnd, R) then
    raise Exception.Create('Could not measure the window');

  Width := R.Width;
  Height := R.Height;
  if (Width <= 0) or (Height <= 0) then
    raise Exception.Create('The window has no visible area (it may be minimised)');

  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf32bit;
    Bmp.SetSize(Width, Height);

    Ok := PrintWindow(Wnd, Bmp.Canvas.Handle, PW_RENDERFULLCONTENT);
    if not Ok then
    begin
      ScreenDC := GetDC(0);
      try
        Ok := BitBlt(Bmp.Canvas.Handle, 0, 0, Width, Height,
          ScreenDC, R.Left, R.Top, SRCCOPY);
      finally
        ReleaseDC(0, ScreenDC);
      end;
    end;
    if not Ok then
      raise Exception.Create('The window could not be captured');

    Stream := TMemoryStream.Create;
    try
      { WIC is COM, and this runs on the RPC worker thread, which nobody has
        initialised. S_FALSE means it was already initialised on this thread -
        still a success, and we still have to balance it. }
      ComHr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
      if Failed(ComHr) then
        raise Exception.Create('Could not initialise COM to encode the image');
      try
        Png := TWICImage.Create;
        try
          Png.Assign(Bmp);
          Png.ImageFormat := wifPng;
          Png.SaveToStream(Stream);
        finally
          Png.Free;
        end;
      finally
        CoUninitialize;
      end;
      Result := TNetEncoding.Base64.EncodeBytesToString(
        Stream.Memory, Stream.Size);
    finally
      Stream.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

function DebuggerServices: IOTADebuggerServices;
begin
  Supports(BorlandIDEServices, IOTADebuggerServices, Result);
end;

function ResolveTarget(const Target, TitleFilter: string): HWND;
var
  Pid: DWORD;
  ErrMsg: string;
begin
  if SameText(Target, 'ide') then
  begin
    Result := FindMainWindowOfProcess(GetCurrentProcessId, TitleFilter);
    if Result = 0 then
      raise Exception.Create('Could not find the RAD Studio main window');
    Exit;
  end;

  if not SameText(Target, 'app') then
    raise Exception.CreateFmt(
      'Unknown target "%s"; expected "app" (the running program) or "ide"', [Target]);

  { ToolsAPI is main-thread-only, so this one lookup gets marshalled even
    though the capture itself does not. A modal will therefore break target
    "app" but not target "ide". }
  Pid := 0;
  ErrMsg := '';
  RunOnMainThread(
    procedure
    var
      DS: IOTADebuggerServices;
    begin
      DS := DebuggerServices;
      if (DS = nil) or (DS.CurrentProcess = nil) then
      begin
        ErrMsg := 'No program is running under the debugger. Call runProject ' +
          'first, and give the application a moment to show its main form.';
        Exit;
      end;
      { OSProcessId, not ProcessId. ProcessId is the debugger's own internal
        handle for the process and matches nothing that EnumWindows reports,
        so using it finds no windows at all and looks exactly like "the app
        has not opened a window yet". }
      Pid := DS.CurrentProcess.OSProcessId;
    end);
  if ErrMsg <> '' then
    raise Exception.Create(ErrMsg);

  Result := FindMainWindowOfProcess(Pid, TitleFilter);
  if Result = 0 then
    raise Exception.Create(
      'The program is running but has no visible top-level window yet. It may ' +
      'still be starting, may be stopped at a breakpoint before its form is ' +
      'shown, or may have failed during startup.');
end;

function ToolCaptureScreenshot(Params: TJSONObject): TJSONValue;
var
  Target, TitleFilter, Data: string;
  Wnd: HWND;
  Width, Height: Integer;
  Obj: TJSONObject;
  Buf: array[0..511] of Char;
begin
  Target := Params.GetValue<string>('target', 'app');
  TitleFilter := Params.GetValue<string>('windowTitle', '');

  Wnd := ResolveTarget(Target, TitleFilter);
  Data := CaptureWindowToPngBase64(Wnd, Width, Height);

  FillChar(Buf, SizeOf(Buf), 0);
  GetWindowText(Wnd, Buf, Length(Buf));

  Obj := TJSONObject.Create;
  Obj.AddPair('format', 'png');
  Obj.AddPair('width', TJSONNumber.Create(Width));
  Obj.AddPair('height', TJSONNumber.Create(Height));
  Obj.AddPair('windowTitle', string(Buf));
  Obj.AddPair('base64', Data);
  Result := Obj;
end;

procedure RegisterCaptureTools(const RegisterFn: TProc<string, TFunc<TJSONObject, TJSONValue>>);
var
  F: TFunc<TJSONObject, TJSONValue>;
begin
  F := ToolCaptureScreenshot; RegisterFn('captureScreenshot', F);
end;

end.
