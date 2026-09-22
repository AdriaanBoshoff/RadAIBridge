<#
.SYNOPSIS
  Removes RAD AI Bridge from RAD Studio.

.DESCRIPTION
  Unregisters the package so RAD Studio stops loading it, and removes the
  discovery file. Your copy of this repository is left alone - delete the
  folder yourself if you no longer want it.

.PARAMETER DeleteBuildOutput
  Also delete the compiled IdePlugin\dcu folder.
#>
[CmdletBinding()]
param([switch]$DeleteBuildOutput)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

Write-Host ""
Write-Host "RAD AI Bridge uninstaller" -ForegroundColor White
Write-Host "-------------------------" -ForegroundColor DarkGray
Write-Host ""

if (Get-Process bds -ErrorAction SilentlyContinue) {
  Write-Host "RAD Studio is running. Close it first, then re-run this script." -ForegroundColor Yellow
  Write-Host ""
  exit 1
}

$removed = 0
if (Test-Path 'HKCU:\SOFTWARE\Embarcadero\BDS') {
  foreach ($ver in Get-ChildItem 'HKCU:\SOFTWARE\Embarcadero\BDS') {
    $knownKey = Join-Path $ver.PSPath 'Known Packages'
    if (-not (Test-Path $knownKey)) { continue }
    Get-ItemProperty -Path $knownKey |
      Get-Member -MemberType NoteProperty |
      Where-Object { $_.Name -like '*RadAiBridge.bpl' } |
      ForEach-Object {
        Remove-ItemProperty -Path $knownKey -Name $_.Name -ErrorAction SilentlyContinue
        Write-Host "  Unregistered from RAD Studio $($ver.PSChildName):" -ForegroundColor Green
        Write-Host "    $($_.Name)" -ForegroundColor Gray
        $script:removed++
      }
  }
}

if ($removed -eq 0) { Write-Host "  No registration found - nothing to unregister." -ForegroundColor Gray }

$discovery = Join-Path $env:APPDATA 'RadAiBridge'
if (Test-Path $discovery) {
  Remove-Item $discovery -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "  Removed $discovery" -ForegroundColor Green
}

if ($DeleteBuildOutput) {
  $dcu = Join-Path $repo 'IdePlugin\dcu'
  if (Test-Path $dcu) {
    Remove-Item $dcu -Recurse -Force
    Write-Host "  Removed $dcu" -ForegroundColor Green
  }
}

Write-Host ""
Write-Host "Done. RAD Studio will no longer load the bridge." -ForegroundColor Green
Write-Host ""
