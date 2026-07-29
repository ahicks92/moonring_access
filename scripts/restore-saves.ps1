# restore-saves.ps1 — restore a Moonring save snapshot made by backup-saves.ps1.
# With no argument, restores the NEWEST snapshot. Refuses to run while the
# game is running. The current save data is replaced (a safety copy of it is
# made first as save-backups\pre-restore-<timestamp>).

param([string]$Snapshot)

$ErrorActionPreference = 'Stop'
if (Get-Process -Name 'Moonring' -ErrorAction SilentlyContinue) {
    Write-Error "Moonring is running; close it before restoring saves."
}

$saveDir = Join-Path $env:APPDATA 'Moonring'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path $repo 'save-backups'

if (-not $Snapshot) {
    $latest = Get-ChildItem $root -Directory -ErrorAction Stop |
        Where-Object { $_.Name -notlike 'pre-restore-*' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Error "No snapshots in $root." }
    $Snapshot = $latest.FullName
} elseif (-not (Test-Path $Snapshot)) {
    $Snapshot = Join-Path $root $Snapshot
}
if (-not (Test-Path $Snapshot)) { Write-Error "Snapshot not found: $Snapshot" }

# Safety copy of the current state, then replace.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safety = Join-Path $root "pre-restore-$stamp"
New-Item -ItemType Directory -Force $safety | Out-Null
$data = Join-Path $saveDir 'data'
if (Test-Path $data) { Copy-Item $data (Join-Path $safety 'data') -Recurse; Remove-Item $data -Recurse -Force }
$opts = Join-Path $saveDir 'moonring_options.sav'
if (Test-Path $opts) { Copy-Item $opts $safety; Remove-Item $opts -Force }

$snapData = Join-Path $Snapshot 'data'
if (Test-Path $snapData) { Copy-Item $snapData $data -Recurse }
$snapOpts = Join-Path $Snapshot 'moonring_options.sav'
if (Test-Path $snapOpts) { Copy-Item $snapOpts $saveDir }

Write-Host "Restored $Snapshot (previous state saved to $safety)"
