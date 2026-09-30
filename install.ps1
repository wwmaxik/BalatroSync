# ==============================================================================
# BalatroSync Installer for Windows
# Automatically installs Lovely Injector, BalatroSync Mod, and TLS helpers.
# ==============================================================================

[CmdletBinding()]
param()

$Host.UI.RawUI.WindowTitle = "BalatroSync Cloud Mod Installer"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "           BalatroSync Cloud Mod Installer (Windows)        " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. Locate Balatro Directory
$BalatroDir = ""

# Method A: Registry check for Steam installation
$SteamPath = $null
try {
    $SteamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
} catch {}

$PotentialPaths = @(
    "$SteamPath\steamapps\common\Balatro",
    "${env:ProgramFiles(x86)}\Steam\steamapps\common\Balatro",
    "${env:ProgramFiles}\Steam\steamapps\common\Balatro",
    "C:\Steam\steamapps\common\Balatro",
    "D:\Steam\steamapps\common\Balatro",
    "D:\SteamLibrary\steamapps\common\Balatro",
    "E:\SteamLibrary\steamapps\common\Balatro",
    "F:\SteamLibrary\steamapps\common\Balatro"
)

# Parse libraryfolders.vdf if SteamPath exists
if ($SteamPath -and (Test-Path "$SteamPath\steamapps\libraryfolders.vdf")) {
    $vdfContent = Get-Content "$SteamPath\steamapps\libraryfolders.vdf"
    foreach ($line in $vdfContent) {
        if ($line -match '"path"\s+"([^"]+)"') {
            $lib = $matches[1].Replace('\\', '\')
            $PotentialPaths += "$lib\steamapps\common\Balatro"
        }
    }
}

foreach ($path in $PotentialPaths) {
    if ($path -and (Test-Path "$path\Balatro.exe")) {
        $BalatroDir = $path
        break
    }
}

if (-not $BalatroDir) {
    Write-Host "[!] Balatro installation not automatically found." -ForegroundColor Yellow
    $userPath = Read-Host "Please enter the full path to your Balatro folder (where Balatro.exe is located)"
    if ($userPath -and (Test-Path "$userPath\Balatro.exe")) {
        $BalatroDir = $userPath
    } else {
        Write-Host "[ERROR] Balatro.exe not found at '$userPath'. Aborting." -ForegroundColor Red
        Pause
        Exit 1
    }
}

Write-Host "[✓] Found Balatro game directory: $BalatroDir" -ForegroundColor Green

# 2. Locate AppData Roaming Balatro directory
$AppDataBalatro = "$env:APPDATA\Balatro"
if (-not (Test-Path $AppDataBalatro)) {
    New-Item -ItemType Directory -Path $AppDataBalatro -Force | Out-Null
}
Write-Host "[✓] AppData directory: $AppDataBalatro" -ForegroundColor Green

# 3. Check & Install Lovely Injector (version.dll)
Write-Host ""
Write-Host "[*] Checking Lovely injector (version.dll)..." -ForegroundColor Yellow
$versionDll = "$BalatroDir\version.dll"

if (Test-Path $versionDll) {
    Write-Host "[✓] Lovely injector (version.dll) is already installed." -ForegroundColor Green
} else {
    Write-Host "[*] Downloading Lovely injector..." -ForegroundColor Yellow
    $LovelyZipUrl = "https://github.com/ethangreen-dev/lovely-injector/releases/download/v0.10.0/lovely-x86_64-pc-windows-msvc.zip"
    $TempZip = "$env:TEMP\lovely_injector.zip"
    $TempExtract = "$env:TEMP\lovely_extract"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $LovelyZipUrl -OutFile $TempZip -UseBasicParsing
        Expand-Archive -Path $TempZip -DestinationPath $TempExtract -Force
        Copy-Item -Path "$TempExtract\version.dll" -Destination $BalatroDir -Force
        Remove-Item -Path $TempZip, $TempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[✓] Installed Lovely injector (version.dll) into $BalatroDir" -ForegroundColor Green
    } catch {
        Write-Host "[!] Failed to auto-download Lovely: $_" -ForegroundColor Red
        Write-Host "Please download Lovely from https://github.com/ethangreen-dev/lovely-injector/releases manually." -ForegroundColor Yellow
    }
}

# 4. Copy TLS Network helpers (curl.exe)
Write-Host ""
Write-Host "[*] Installing network helpers..." -ForegroundColor Yellow
if (Test-Path "$ScriptDir\bin\curl.exe") {
    Copy-Item -Path "$ScriptDir\bin\curl.exe" -Destination $BalatroDir -Force
    if (Test-Path "$ScriptDir\bin\libcurl-x64.dll") {
        Copy-Item -Path "$ScriptDir\bin\libcurl-x64.dll" -Destination $BalatroDir -Force
    }
    if (Test-Path "$ScriptDir\bin\curl-ca-bundle.crt") {
        Copy-Item -Path "$ScriptDir\bin\curl-ca-bundle.crt" -Destination $BalatroDir -Force
    }
    Write-Host "[✓] Network helpers installed." -ForegroundColor Green
}

# 5. Install BalatroSync Mod
Write-Host ""
Write-Host "[*] Installing BalatroSync mod files..." -ForegroundColor Yellow

$GameModsDir = "$BalatroDir\Mods\BalatroSync"
$AppModsDir = "$AppDataBalatro\Mods\BalatroSync"

New-Item -ItemType Directory -Path $GameModsDir -Force | Out-Null
New-Item -ItemType Directory -Path $AppModsDir -Force | Out-Null

Copy-Item -Path "$ScriptDir\Mod\lovely.toml" -Destination $GameModsDir -Force
Copy-Item -Path "$ScriptDir\Mod\sync_mod.lua" -Destination $GameModsDir -Force
Copy-Item -Path "$ScriptDir\Mod\sync_thread.lua" -Destination $GameModsDir -Force

Copy-Item -Path "$ScriptDir\Mod\lovely.toml" -Destination $AppModsDir -Force
Copy-Item -Path "$ScriptDir\Mod\sync_mod.lua" -Destination $AppModsDir -Force
Copy-Item -Path "$ScriptDir\Mod\sync_thread.lua" -Destination $AppModsDir -Force

Write-Host "[✓] BalatroSync mod files installed." -ForegroundColor Green

# 6. Configuration setup
Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "You can paste your Setup Code (URL#TOKEN) now,"
Write-Host "or press ENTER to configure later directly in the in-game GUI!"
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
$setupCode = Read-Host "Paste Setup Code or press [ENTER] to skip"

$workerUrl = "https://balatro-sync.your-subdomain.workers.dev"
$authToken = "your-secret-auth-token"
$deviceId = "PC-SECONDARY"

if ($setupCode -match "(https?://[^#\s]+)#([^\s]+)") {
    $workerUrl = $matches[1]
    $authToken = $matches[2]
    Write-Host "[✓] Parsed Setup Code successfully!" -ForegroundColor Green
}

$configJson = @"
{
  "worker_url": "$workerUrl",
  "auth_token": "$authToken",
  "device_id": "$deviceId",
  "auto_sync": true
}
"@

$ConfigPath1 = "$GameModsDir\config.json"
$ConfigPath2 = "$AppModsDir\config.json"

if (-not (Test-Path $ConfigPath1) -or ($workerUrl -ne "https://balatro-sync.your-subdomain.workers.dev")) {
    Set-Content -Path $ConfigPath1 -Value $configJson -Encoding UTF8
    Set-Content -Path $ConfigPath2 -Value $configJson -Encoding UTF8
    Write-Host "[✓] Created config.json" -ForegroundColor Green
} else {
    Write-Host "[✓] Preserved existing config.json" -ForegroundColor Green
}

# 7. Complete
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "           BalatroSync Installation Complete!               " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "How to use in game:" -ForegroundColor Cyan
Write-Host "1. Launch Balatro."
Write-Host "2. Go to: Options -> Settings -> Cloud Sync tab."
Write-Host "3. You can click [ Paste All ] if you have a code copied, or test the connection."
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
