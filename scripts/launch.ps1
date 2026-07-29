# Launch Moonring with MoonringAccess and wait for the mod's dev server.
#
# Launches the executable DIRECTLY, not through Steam, for one reason: it is
# the only way to set the window's initial show state, and therefore the only
# way to launch without stealing focus. A game that takes focus interrupts the
# developer's screen reader mid-sentence, every single test run.
#
# CreateProcess with STARTF_USESHOWWINDOW and SW_SHOWMINNOACTIVE means the
# window never asks for the foreground. Windows' foreground lock does NOT help
# here: it grants foreground rights to "a process started by the foreground
# process", which is exactly this case. Start-Process cannot express this -
# its -WindowStyle Minimized maps to SW_SHOWMINIMIZED, which activates.
# (Pattern proven in the soundz project's launcher.)
#
# Moonring's Steam integration is pcall-guarded (main.lua try_init_steam) and
# the game runs fine without Steam, so no SteamAppId bypass is required.
#
# Because we create the process, it inherits OUR environment, so
# MOONRING_ACCESS_* variables actually reach the game.
#
# Trade-off: a direct launch does not sync Steam Cloud; saves stay local.
# Use -ViaSteam for a launch that behaves exactly like a player's.

param(
    [int]$Port = 8771,
    [int]$TimeoutSeconds = 120,

    # Skip waiting for the dev server (used before Phase 1 exists, or for
    # player-realistic runs).
    [switch]$NoServer,

    # Launch through Steam instead. Steals focus; ignores our env vars.
    [switch]$ViaSteam,

    # Let the mod speak. Off by default: mod speech goes through the
    # developer's own screen reader, so an unattended run would talk over
    # whatever they are doing. The /speech endpoint records everything either
    # way, so muting costs a test nothing.
    [switch]$Speak,

    [string]$GameDir
)

$ErrorActionPreference = 'Stop'

$running = Get-Process -Name 'Moonring' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "Moonring is already running (pid $($running.Id)). Close it first." -ForegroundColor Yellow
    exit 1
}

if (-not $Speak) { $env:MOONRING_ACCESS_MUTE = '1' } else { Remove-Item Env:\MOONRING_ACCESS_MUTE -ErrorAction SilentlyContinue }

if ($ViaSteam) {
    Write-Host "Launching Moonring via Steam - this will steal focus ..."
    Start-Process "steam://run/2373630"   # if this appid is wrong Steam shows a picker; direct launch is the supported path
} else {
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
        Write-Host "Could not find the game executable at: $exe" -ForegroundColor Red
        exit 1
    }

    Add-Type -Namespace MoonringAccess -Name Launch -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }

[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct STARTUPINFO {
  public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
  public int dwX; public int dwY; public int dwXSize; public int dwYSize;
  public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
  public int dwFlags; public short wShowWindow; public short cbReserved2;
  public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
}

[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool CreateProcess(string lpApplicationName, string lpCommandLine,
  IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags,
  IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
'@

    $si = New-Object MoonringAccess.Launch+STARTUPINFO
    $si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
    $si.dwFlags = 0x00000001      # STARTF_USESHOWWINDOW
    $si.wShowWindow = 7           # SW_SHOWMINNOACTIVE - shown, but never activated
    $pi = New-Object MoonringAccess.Launch+PROCESS_INFORMATION

    Write-Host "Launching Moonring directly (no focus steal$(if(-not $Speak){', muted'})) ..."
    $ok = [MoonringAccess.Launch]::CreateProcess($exe, $null, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0,
                                                 [IntPtr]::Zero, (Split-Path $exe), [ref]$si, [ref]$pi)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host "CreateProcess failed (win32 error $err)." -ForegroundColor Red
        exit 1
    }
}

if ($NoServer) {
    Write-Host "Launched (dev-server wait skipped)."
    exit 0
}

Write-Host "Waiting for the MoonringAccess dev server on 127.0.0.1:$Port ..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$seen = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -UseBasicParsing
        Write-Host ""
        Write-Host $r.Content
        Write-Host "Dev server is up." -ForegroundColor Green
        exit 0
    } catch {
        # Once the process has been seen alive, its disappearance means the
        # game quit or crashed - report that instead of waiting in silence.
        if (Get-Process -Name 'Moonring' -ErrorAction SilentlyContinue) {
            $seen = $true
        } elseif ($seen) {
            Write-Host "Moonring exited before the dev server came up." -ForegroundColor Red
            Write-Host "Check lovely's log in the game folder / Mods\lovely."
            exit 1
        }
        Start-Sleep -Milliseconds 1000
    }
}

Write-Host "Timed out after $TimeoutSeconds s without a response from the dev server." -ForegroundColor Red
exit 1
