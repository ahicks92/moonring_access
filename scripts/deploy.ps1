# deploy.ps1 — one-command dev install for MoonringAccess.
#
#   1. Finds the Moonring install (Steam registry; override with -GameDir).
#   2. Installs the bundled Lovely Injector (third_party\lovely\version.dll)
#      next to Moonring.exe (skipped if identical file already there).
#   3. Links %APPDATA%\Moonring\Mods\MoonringAccess -> <repo>\src as a
#      directory junction, so editing the repo updates the installed mod
#      (restart the game to pick changes up). No admin needed for the link;
#      writing version.dll into Program Files MAY need elevation - the script
#      says so if it hits that.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
#   ... -GameDir "D:\Games\Moonring"   explicit game folder (contains Moonring.exe)
#   ... -Uninstall                     remove the mod link (Lovely left alone)

param(
    [string]$GameDir,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src  = Join-Path $repo 'src'
$mods = Join-Path $env:APPDATA 'Moonring\Mods'
$link = Join-Path $mods 'MoonringAccess'

function Write-Step($msg) { Write-Host "== $msg" }

if ($Uninstall) {
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $item.Delete()
            Write-Host "Removed mod link: $link"
        } else {
            Write-Warning "'$link' is a real folder, not this script's link; not touching it."
        }
    } else {
        Write-Host "No mod link at $link; nothing to do."
    }
    exit 0
}

# --- Locate the game ---------------------------------------------------------
if (-not $GameDir) {
    $steamPath = $null
    try {
        $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch {}
    if ($steamPath) { $GameDir = Join-Path $steamPath 'steamapps\common\Moonring' }
    if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'Moonring.exe'))) {
        $GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\Moonring'
    }
}
$exe = Join-Path $GameDir 'Moonring.exe'
if (-not (Test-Path $exe)) {
    Write-Error "Moonring.exe not found at '$GameDir'. Pass -GameDir."
}
Write-Step "Game: $GameDir"

# --- Install Lovely ----------------------------------------------------------
$dllSrc = Join-Path $repo 'third_party\lovely\version.dll'
$dllDst = Join-Path $GameDir 'version.dll'
$needCopy = $true
if (Test-Path $dllDst) {
    $a = Get-FileHash $dllSrc -Algorithm SHA256
    $b = Get-FileHash $dllDst -Algorithm SHA256
    if ($a.Hash -eq $b.Hash) { $needCopy = $false; Write-Step "Lovely already installed (identical version.dll)." }
    else { Write-Warning "A DIFFERENT version.dll exists in the game folder; replacing it." }
}
if ($needCopy) {
    try {
        Copy-Item $dllSrc $dllDst -Force
        Write-Step "Installed Lovely: $dllDst"
    } catch {
        Write-Error "Could not write $dllDst - run this script from an elevated PowerShell. ($_)"
    }
}

# --- Mod junction ------------------------------------------------------------
if (-not (Test-Path $mods)) { New-Item -ItemType Directory -Force $mods | Out-Null }
if (Test-Path $link) {
    $item = Get-Item $link -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $item.Delete()
    } else {
        Write-Error "'$link' exists and is a real folder (not a link). Move it aside first."
    }
}
New-Item -ItemType Junction -Path $link -Target $src | Out-Null
Write-Step "Linked $link -> $src"
Write-Host "Done. Launch with scripts\launch.ps1."
