<#
.SYNOPSIS
  Developer loop: recompile the plugin, redeploy it, restart RAD Studio.

.DESCRIPTION
  For working ON the bridge. If you just want to install it, run ..\install.ps1
  instead.

  A .bpl cannot hot-reload, so every change to the plugin needs a full IDE
  restart. This does the whole cycle and waits until the bridge reports itself
  up again.

  It always closes RAD Studio before copying. Writing over a .bpl that a
  running IDE has mapped appears to succeed but leaves an image the next IDE
  start silently fails to load - no error dialog, the package simply never
  appears in the process. That is a miserable failure to diagnose, so this
  makes it impossible.

.PARAMETER BdsVersion
  RAD Studio version, e.g. "37.0". Auto-detected when only one is installed.

.PARAMETER NoStart
  Compile and deploy, but do not restart the IDE.

.EXAMPLE
  .\rebuild.ps1
#>
[CmdletBinding()]
param(
  [string]$BdsVersion,
  [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$installs = Get-ChildItem 'HKCU:\SOFTWARE\Embarcadero\BDS' -ErrorAction SilentlyContinue | ForEach-Object {
  $root = (Get-ItemProperty $_.PSPath -Name RootDir -ErrorAction SilentlyContinue).RootDir
  if ($root -and (Test-Path (Join-Path $root 'bin\dcc32.exe'))) {
    [pscustomobject]@{ Version = $_.PSChildName; RootDir = $root.TrimEnd('\') }
  }
} | Where-Object { $_ }

if ($BdsVersion) { $bds = $installs | Where-Object { $_.Version -eq $BdsVersion } | Select-Object -First 1 }
else             { $bds = $installs | Select-Object -First 1 }
if (-not $bds) { Write-Error "No usable RAD Studio installation found."; exit 1 }

$dcc32   = Join-Path $bds.RootDir 'bin\dcc32.exe'
$bdsExe  = Join-Path $bds.RootDir 'bin\bds.exe'
$libPath = Join-Path $bds.RootDir 'lib\Win32\release'
$outDir  = Join-Path $here 'dcu\Win32\Debug'
$deploy  = Join-Path $outDir 'RadAiBridge.bpl'
$discovery = Join-Path $env:APPDATA 'RadAiBridge\bridge.json'

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "==> compiling (RAD Studio $($bds.Version))" -ForegroundColor Cyan
Push-Location $here
try {
  & $dcc32 -B RadAiBridge.dpk -U"$libPath" -I"$libPath" -N0"dcu\Win32\Debug" -LE"." -LN"."
  if ($LASTEXITCODE -ne 0) { Write-Error "Compile failed."; exit 1 }
} finally { Pop-Location }

Write-Host "==> closing any running IDE" -ForegroundColor Cyan
Get-Process bds -ErrorAction SilentlyContinue | Stop-Process -Force
for ($i = 0; $i -lt 20 -and (Get-Process bds -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }

Write-Host "==> deploying to $deploy" -ForegroundColor Cyan
Copy-Item -Force (Join-Path $here 'RadAiBridge.bpl') $deploy

Remove-Item $discovery -ErrorAction SilentlyContinue

if ($NoStart) { Write-Host "==> not starting the IDE (-NoStart)" -ForegroundColor Yellow; exit 0 }

Write-Host "==> starting IDE" -ForegroundColor Cyan
Start-Process $bdsExe

Write-Host "==> waiting for the bridge" -ForegroundColor Cyan
for ($i = 0; $i -lt 24; $i++) {
  if (Test-Path $discovery) {
    Write-Host "bridge up: $((Get-Content $discovery -Raw).Trim())" -ForegroundColor Green
    exit 0
  }
  Start-Sleep -Seconds 5
}
Write-Error "Bridge did not come up within 120s."
exit 1
