# backup-saves.ps1 — snapshot Moonring's save data before automated test runs.
# Copies <savedir>\data (all saves live under it) plus the options file into
# save-backups\<timestamp>\ in the repo. Restore with restore-saves.ps1.

$ErrorActionPreference = 'Stop'
$saveDir = Join-Path $env:APPDATA 'Moonring'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $repo "save-backups\$stamp"

if (-not (Test-Path $saveDir)) { Write-Host "No save dir at $saveDir; nothing to back up."; exit 0 }

New-Item -ItemType Directory -Force $dest | Out-Null
$data = Join-Path $saveDir 'data'
if (Test-Path $data) { Copy-Item $data (Join-Path $dest 'data') -Recurse }
$opts = Join-Path $saveDir 'moonring_options.sav'
if (Test-Path $opts) { Copy-Item $opts $dest }

Write-Host "Backed up to $dest"
