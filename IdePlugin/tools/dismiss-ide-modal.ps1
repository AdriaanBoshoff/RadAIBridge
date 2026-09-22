<#
Finds a modal dialog owned by the RAD Studio process and clicks one of its
buttons.

Why this exists: RadAiBridge tool handlers run on the IDE main thread, so ANY
modal dialog blocks every bridge call until it is dismissed. UI Automation is
useless in that state - it queries the same blocked thread - but the modal runs
its own message loop, so plain window messages still get through.

The dialogs are CHILD windows of the bds main window, so a top-level enumeration
alone misses them; both scopes are searched.

Usage:
  dismiss-ide-modal.ps1            # report what is showing, click nothing
  dismiss-ide-modal.ps1 -Button No # click the button captioned "No"
#>
[CmdletBinding()]
param(
  [string]$Button,
  [string]$TitlePattern = '^(Error|Warning|Confirm|Information|Save|Debugger|Rebuild)'
)

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
}
"@

function Get-Text([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 512
  [void][W]::GetWindowText($h, $sb, 512)
  $sb.ToString()
}
function Get-Class([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 512
  [void][W]::GetClassName($h, $sb, 512)
  $sb.ToString()
}

$bds = Get-Process bds -ErrorAction SilentlyContinue
if (-not $bds) { Write-Output 'no bds process'; return }
$targetPid = $bds.Id

$dialogs = New-Object System.Collections.ArrayList
$findDialogs = [W+EnumProc]{
  param($h, $p)
  $procId = 0
  [void][W]::GetWindowThreadProcessId($h, [ref]$procId)
  if ($procId -eq $targetPid -and [W]::IsWindowVisible($h)) {
    $t = Get-Text $h
    if ($t -match $TitlePattern -and (Get-Class $h) -ne 'TErrorControl') {
      [void]$dialogs.Add([pscustomobject]@{ H = $h; Title = $t })
    }
  }
  return $true
}

[void][W]::EnumWindows($findDialogs, [IntPtr]::Zero)
[void][W]::EnumChildWindows($bds.MainWindowHandle, $findDialogs, [IntPtr]::Zero)

if ($dialogs.Count -eq 0) { Write-Output 'no modal found'; return }

$BM_CLICK = 0x00F5
$WM_CLOSE = 0x0010

foreach ($d in $dialogs) {
  # Collect this dialog's buttons so the caller can see the real choices
  # rather than guessing at them.
  $buttons = New-Object System.Collections.ArrayList
  $findButtons = [W+EnumProc]{
    param($h, $p)
    if ((Get-Class $h) -like '*BUTTON*' -or (Get-Class $h) -like 'TButton*') {
      $caption = (Get-Text $h).Replace('&', '')
      [void]$buttons.Add([pscustomobject]@{ H = $h; Text = $caption })
    }
    return $true
  }
  [void][W]::EnumChildWindows($d.H, $findButtons, [IntPtr]::Zero)

  Write-Output ("dialog: '{0}' buttons: [{1}]" -f $d.Title, (($buttons | ForEach-Object { $_.Text }) -join ', '))

  if (-not $Button) { continue }

  [void][W]::SetForegroundWindow($d.H)
  Start-Sleep -Milliseconds 150

  $match = $buttons | Where-Object { $_.Text -eq $Button } | Select-Object -First 1
  if ($match) {
    Write-Output ("  clicking '{0}'" -f $match.Text)
    [void][W]::SendMessage($match.H, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
  } else {
    Write-Output ("  no button '{0}'; closing the dialog instead" -f $Button)
    [void][W]::SendMessage($d.H, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 300
}
