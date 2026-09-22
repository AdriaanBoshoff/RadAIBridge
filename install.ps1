<#
.SYNOPSIS
  Installs RAD AI Bridge: builds the IDE plugin, registers it with RAD Studio,
  builds the MCP server, and verifies the whole chain works.

.DESCRIPTION
  Run this from a normal PowerShell window. It does not need Administrator -
  everything it touches is under HKEY_CURRENT_USER and your own profile.

  Steps, in order:
    1. Find your RAD Studio installation
    2. Check Node.js is present
    3. Close RAD Studio (it cannot be running while the plugin is deployed)
    4. Compile RadAiBridge.bpl with dcc32
    5. Register the package with RAD Studio
    6. Build the MCP server (npm install + npm run build)
    7. Start RAD Studio and confirm the bridge came up

.PARAMETER BdsVersion
  Which RAD Studio to install into, e.g. "37.0". Only needed if you have more
  than one and do not want to be asked.

.PARAMETER SkipMcpServer
  Build only the IDE plugin, not the Node MCP server.

.PARAMETER NoStart
  Do not launch RAD Studio at the end. The install is still complete; the
  bridge starts the next time you open the IDE yourself.

.PARAMETER CloseIde
  Close a running RAD Studio without asking. Useful for unattended installs.
  Anything unsaved in the IDE is lost, so only pass this when you know it is
  safe.

.EXAMPLE
  .\install.ps1

.EXAMPLE
  .\install.ps1 -BdsVersion 37.0 -NoStart
#>
[CmdletBinding()]
param(
  [string]$BdsVersion,
  [switch]$SkipMcpServer,
  [switch]$NoStart,
  [switch]$CloseIde
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Write-Step  ($n, $m) { Write-Host ""; Write-Host "[$n/7] $m" -ForegroundColor Cyan }
function Write-Ok    ($m)     { Write-Host "      $m" -ForegroundColor Green }
function Write-Info  ($m)     { Write-Host "      $m" -ForegroundColor Gray }
function Write-Warn2 ($m)     { Write-Host "      $m" -ForegroundColor Yellow }

function Fail ($message, $fix) {
  Write-Host ""
  Write-Host "INSTALL FAILED" -ForegroundColor Red
  Write-Host "  $message" -ForegroundColor Red
  if ($fix) { Write-Host ""; Write-Host "  What to do: $fix" -ForegroundColor Yellow }
  Write-Host ""
  exit 1
}

Write-Host ""
Write-Host "RAD AI Bridge installer" -ForegroundColor White
Write-Host "-----------------------" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 1. RAD Studio
Write-Step 1 "Looking for RAD Studio"

$installs = @()
if (Test-Path 'HKCU:\SOFTWARE\Embarcadero\BDS') {
  $installs = Get-ChildItem 'HKCU:\SOFTWARE\Embarcadero\BDS' | ForEach-Object {
    $root = (Get-ItemProperty $_.PSPath -Name RootDir -ErrorAction SilentlyContinue).RootDir
    if ($root -and (Test-Path (Join-Path $root 'bin\dcc32.exe'))) {
      [pscustomobject]@{
        Version = $_.PSChildName
        RootDir = $root.TrimEnd('\')
        RegPath = $_.PSPath
      }
    }
  } | Where-Object { $_ }
}

if (-not $installs -or $installs.Count -eq 0) {
  Fail "No RAD Studio installation with a command-line compiler (dcc32.exe) was found." `
       "Install RAD Studio / Delphi, or if it is installed for a different Windows user, run this as that user."
}

if ($BdsVersion) {
  $bds = $installs | Where-Object { $_.Version -eq $BdsVersion } | Select-Object -First 1
  if (-not $bds) {
    Fail "RAD Studio version '$BdsVersion' was not found. Available: $(($installs.Version) -join ', ')" `
         "Re-run without -BdsVersion to choose from the list."
  }
} elseif ($installs.Count -eq 1) {
  $bds = $installs[0]
} else {
  Write-Info "More than one RAD Studio is installed:"
  for ($i = 0; $i -lt $installs.Count; $i++) {
    Write-Host ("        [{0}] {1}  ({2})" -f $i, $installs[$i].Version, $installs[$i].RootDir)
  }
  $choice = Read-Host "      Which one? Enter a number"
  if ($choice -notmatch '^\d+$' -or [int]$choice -ge $installs.Count) { Fail "'$choice' is not one of the listed numbers." }
  $bds = $installs[[int]$choice]
}

$dcc32   = Join-Path $bds.RootDir 'bin\dcc32.exe'
$bdsExe  = Join-Path $bds.RootDir 'bin\bds.exe'
$libPath = Join-Path $bds.RootDir 'lib\Win32\release'

if (-not (Test-Path $libPath)) {
  Fail "The Win32 release library path is missing: $libPath" `
       "Your RAD Studio install may be incomplete. Repair it from the installer."
}

Write-Ok "RAD Studio $($bds.Version)"
Write-Info $bds.RootDir

# --------------------------------------------------------------------- 2. Node
Write-Step 2 "Checking Node.js"

if ($SkipMcpServer) {
  Write-Info "Skipped (-SkipMcpServer)."
} else {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    Fail "Node.js is not installed, or not on your PATH." `
         "Install the LTS build from https://nodejs.org, close this window, open a new PowerShell and re-run. Or use -SkipMcpServer to install just the IDE plugin."
  }
  $nodeVer = (& node --version) -replace '^v', ''
  if ([int]($nodeVer -split '\.')[0] -lt 18) {
    Fail "Node.js $nodeVer is too old; version 18 or newer is required." "Update Node.js from https://nodejs.org."
  }
  Write-Ok "Node.js $nodeVer"
}

# ---------------------------------------------------------- 3. Close RAD Studio
Write-Step 3 "Making sure RAD Studio is closed"

# A .bpl that a running IDE has mapped cannot be safely replaced. The copy
# appears to succeed but leaves an image the next IDE start silently refuses to
# load - no error, the package simply never appears. So: never deploy over a
# running IDE.
$running = Get-Process bds -ErrorAction SilentlyContinue
if ($running) {
  Write-Warn2 "RAD Studio is currently running and must be closed to continue."
  if ($CloseIde) {
    Write-Warn2 "Closing it (-CloseIde)."
  } else {
    Write-Warn2 "Save any work now."
    $answer = Read-Host "      Close it automatically? [y/N]"
    if ($answer -notmatch '^[Yy]') {
      Fail "RAD Studio is still running." "Close RAD Studio yourself, then re-run this script."
    }
  }
  $running | Stop-Process -Force
  for ($i = 0; $i -lt 20 -and (Get-Process bds -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
  if (Get-Process bds -ErrorAction SilentlyContinue) { Fail "RAD Studio did not close." "Close it from Task Manager and re-run." }
  Write-Ok "Closed."
} else {
  Write-Ok "Not running."
}

# ------------------------------------------------------------ 4. Build the .bpl
Write-Step 4 "Compiling the IDE plugin (Win32)"

# bds.exe is a 32-bit process, so design-time packages must be Win32 regardless
# of what platforms the user's own projects target.
$pluginDir = Join-Path $repo 'IdePlugin'
$outDir    = Join-Path $pluginDir 'dcu\Win32\Debug'
$bplPath   = Join-Path $outDir 'RadAiBridge.bpl'

if (-not (Test-Path (Join-Path $pluginDir 'RadAiBridge.dpk'))) {
  Fail "RadAiBridge.dpk was not found in $pluginDir" "Run this script from the folder it came in, without moving it."
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Push-Location $pluginDir
try {
  $log = & $dcc32 -B RadAiBridge.dpk -U"$libPath" -I"$libPath" -N0"dcu\Win32\Debug" -LE"." -LN"." 2>&1
  $compilerExit = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($compilerExit -ne 0) {
  $log | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
  Fail "The plugin did not compile." "Send the compiler output above when reporting this."
}
Write-Ok (($log | Where-Object { $_ -match 'lines,' } | Select-Object -Last 1) -replace '^\s+', '')

$built = Join-Path $pluginDir 'RadAiBridge.bpl'
if (-not (Test-Path $built)) { Fail "The compiler reported success but RadAiBridge.bpl was not produced." }
Copy-Item -Force $built $bplPath
Write-Info "Installed to $bplPath"

# ----------------------------------------------------------------- 5. Register
Write-Step 5 "Registering the package with RAD Studio"

$knownKey = Join-Path $bds.RegPath 'Known Packages'
if (-not (Test-Path $knownKey)) { New-Item -Path $knownKey -Force | Out-Null }

# Drop any earlier registration of this package from another folder, otherwise
# the IDE tries to load a stale path as well.
Get-ItemProperty -Path $knownKey |
  Get-Member -MemberType NoteProperty |
  Where-Object { $_.Name -like '*RadAiBridge.bpl' -and $_.Name -ne $bplPath } |
  ForEach-Object {
    Write-Info "Removing previous registration: $($_.Name)"
    Remove-ItemProperty -Path $knownKey -Name $_.Name -ErrorAction SilentlyContinue
  }

New-ItemProperty -Path $knownKey -Name $bplPath `
  -Value 'RAD AI Bridge - MCP interface for RAD Studio' -PropertyType String -Force | Out-Null
Write-Ok "Registered."

# ------------------------------------------------------------- 6. MCP server
Write-Step 6 "Building the MCP server"

if ($SkipMcpServer) {
  Write-Info "Skipped (-SkipMcpServer)."
} else {
  $mcpDir = Join-Path $repo 'McpServer'
  Push-Location $mcpDir
  try {
    Write-Info "npm install ..."
    & npm install --no-fund --no-audit 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "npm install failed." "Check your internet connection and any corporate proxy settings." }

    Write-Info "npm run build ..."
    $buildLog = & npm run build 2>&1
    if ($LASTEXITCODE -ne 0) {
      $buildLog | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
      Fail "The MCP server did not build."
    }
  } finally {
    Pop-Location
  }
  if (-not (Test-Path (Join-Path $mcpDir 'dist\index.js'))) { Fail "The build finished but dist\index.js is missing." }
  Write-Ok "Built McpServer\dist\index.js"
}

# ----------------------------------------------------------------- 7. Verify
Write-Step 7 "Starting RAD Studio and checking the bridge"

$discovery = Join-Path $env:APPDATA 'RadAiBridge\bridge.json'
Remove-Item $discovery -ErrorAction SilentlyContinue

if ($NoStart) {
  Write-Info "Skipped (-NoStart). The bridge will start next time you open RAD Studio."
} else {
  Start-Process $bdsExe
  Write-Info "Waiting for the plugin to report in (up to 2 minutes)..."
  $up = $false
  for ($i = 0; $i -lt 24; $i++) {
    if (Test-Path $discovery) { $up = $true; break }
    Start-Sleep -Seconds 5
  }
  if ($up) {
    $cfg = Get-Content $discovery -Raw
    Write-Ok "Bridge is live: $($cfg.Trim())"
  } else {
    Write-Warn2 "RAD Studio started but the bridge did not report in."
    Write-Warn2 "Check Component > Install Packages - 'RAD AI Bridge' should be listed and ticked."
    Write-Warn2 "If it is unticked, tick it. If it is missing, re-run this installer."
  }
}

# -------------------------------------------------------------------- Summary
$mcpJsonPath = (Join-Path $repo 'McpServer\dist\index.js')
Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host ""
Write-Host "Last step - tell your AI agent where the server is." -ForegroundColor White
Write-Host "For Claude Code, add this to your .mcp.json:" -ForegroundColor Gray
Write-Host ""
Write-Host '  {' -ForegroundColor DarkGray
Write-Host '    "mcpServers": {' -ForegroundColor DarkGray
Write-Host '      "rad-ai-bridge": {' -ForegroundColor DarkGray
Write-Host '        "command": "node",' -ForegroundColor DarkGray
Write-Host ('        "args": ["{0}"]' -f $mcpJsonPath.Replace('\', '\\')) -ForegroundColor DarkGray
Write-Host '      }' -ForegroundColor DarkGray
Write-Host '    }' -ForegroundColor DarkGray
Write-Host '  }' -ForegroundColor DarkGray
Write-Host ""
Write-Host "Then start RAD Studio first, your agent second." -ForegroundColor Gray
Write-Host ""
