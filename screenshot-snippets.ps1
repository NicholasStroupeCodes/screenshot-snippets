#requires -Version 5.1
<#
.SYNOPSIS
    Screenshot-snippets - clipboard image watcher for Windows terminals.

.DESCRIPTION
    Runs in the background and watches the clipboard. When you snip a
    screenshot (Win+Shift+S, Snipping Tool, PrintScreen), the image lands on
    the Windows clipboard. If the foreground window is a terminal, this script:

      1. Saves the image to a PNG file in the configured output directory.
      2. Puts the quoted file path on the clipboard AS WELL AS the image.

    Both stay on the clipboard, so every kind of CLI gets what it needs:
      - A terminal text paste (Ctrl+V in cmd, Windows Terminal, Cursor) pastes
        the path, which Claude Code reads like any dragged file.
      - A CLI with its own image paste (Codex reads the clipboard image
        directly) still finds the image. Replacing the image with text, as
        earlier versions did, left Codex with "no image on clipboard".

    If the foreground window is NOT a terminal (Slack, Discord, browser, etc.),
    the clipboard is left untouched.

    Only one watcher runs at a time (a named mutex). The clipboard is opened
    only when its contents change (GetClipboardSequenceNumber), never on a
    timer, so the watcher does not fight other apps for the clipboard lock.

.PARAMETER OutputDir
    Directory where captured PNGs are saved. Defaults to the system TEMP folder.

.PARAMETER PollMs
    How often to check the clipboard sequence number and foreground window, in
    milliseconds. Defaults to 250. Checking is cheap and does not open the
    clipboard.

.PARAMETER Once
    Convert whatever image is on the clipboard right now, ignoring the
    foreground check, then exit. For testing.

.EXAMPLE
    .\screenshot-snippets.ps1

.EXAMPLE
    .\screenshot-snippets.ps1 -OutputDir "$env:USERPROFILE\Pictures\Snips" -PollMs 200
#>
[CmdletBinding()]
param(
    [string]$OutputDir = $env:SCREENSHOT_SNIPPETS_DIR,
    [int]$PollMs = 250,
    [switch]$Once
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

if (-not $OutputDir) {
    $OutputDir = $env:TEMP
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$LogPath = Join-Path $env:TEMP "screenshot-snippets.log"
# The watcher runs for weeks; without a cap the log reached 167 MB.
$MaxLogBytes = 2MB
$HeartbeatEvery = [TimeSpan]::FromMinutes(5)

# Marks clipboard contents this watcher wrote, so it never converts its own
# output a second time.
$MarkerFormat = "ScreenshotSnippets.Converted"

# Process names that count as terminals OR have a terminal embedded in them
# (Cursor, VS Code integrated terminals, JetBrains IDEs, etc.).
$TerminalProcessNames = @(
    "cmd",
    "powershell",
    "pwsh",
    "WindowsTerminal",
    "ConEmuC", "ConEmuC64",
    "OpenConsole",
    "conhost",
    "mintty",
    "Cursor",
    "Code",
    "Code - Insiders",
    "wezterm-gui",
    "Hyper",
    "alacritty",
    "tabby",
    "wt"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# P/Invoke for foreground-window detection and the clipboard sequence number.
# Without the foreground check we'd touch clipboard images in EVERY app.
# ---------------------------------------------------------------------------

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class SnippetsWin32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    // Changes every time the clipboard contents change. Reading it does not
    // open the clipboard, so polling it never blocks another app's copy/paste.
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
"@

function Get-ForegroundClass {
    $hwnd = [SnippetsWin32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 256
    [SnippetsWin32]::GetClassName($hwnd, $sb, 256) | Out-Null
    return $sb.ToString()
}

function Get-ForegroundTitle {
    $hwnd = [SnippetsWin32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 512
    [SnippetsWin32]::GetWindowText($hwnd, $sb, 512) | Out-Null
    return $sb.ToString()
}

function Get-ForegroundProcessName {
    $hwnd = [SnippetsWin32]::GetForegroundWindow()
    $procId = 0
    [SnippetsWin32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
    try {
        return (Get-Process -Id $procId -ErrorAction Stop).ProcessName
    } catch {
        return ""
    }
}

function Test-IsTerminal {
    $proc = Get-ForegroundProcessName
    if ($proc -and ($TerminalProcessNames -contains $proc)) {
        return $true
    }
    $cls = Get-ForegroundClass
    if ($cls -eq "ConsoleWindowClass") { return $true }
    if ($cls -eq "CASCADIA_HOSTING_WINDOW_CLASS") { return $true }
    if ($cls -eq "VirtualConsoleClass") { return $true }
    if ($cls -eq "mintty") { return $true }
    # Electron-based editors share Chrome_WidgetWin_1 - only trust when
    # the title strongly suggests a terminal context.
    if ($cls -eq "Chrome_WidgetWin_1") {
        $title = Get-ForegroundTitle
        if ($title -match "(Cursor|Visual Studio Code|Terminal|PowerShell|cmd|Bash|claude|codex|kimi)") {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Logging, capped so a watcher that runs for weeks stays small.
# ---------------------------------------------------------------------------

function Limit-Log {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
            Move-Item -Path $LogPath -Destination "$LogPath.old" -Force
        }
    } catch {}
}

function Write-Log([string]$msg) {
    try {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [$PID] $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch {}
}

# ---------------------------------------------------------------------------
# Clipboard work. Each function opens the clipboard once, briefly.
# ---------------------------------------------------------------------------

# True when the clipboard holds an image this watcher has not converted yet.
function Test-UnconvertedImage {
    try {
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($null -eq $data) { return $false }
        if ($data.GetDataPresent($MarkerFormat)) { return $false }
        return $data.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap)
    } catch {
        return $false
    }
}

# Save the clipboard image to a PNG and put image + path back together.
# Returns $true when the clipboard now holds the converted contents.
function Convert-ClipboardImage {
    $img = $null
    $png = $null
    try {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -eq $img) { return $false }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $path = Join-Path $OutputDir "clip-$stamp.png"
        $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $text = "`"$path`""

        # Image AND path in one clipboard entry:
        #   Bitmap        - CF_BITMAP; Windows synthesizes CF_DIB / CF_DIBV5
        #                   from it, which is what Codex (arboard) reads.
        #   PNG           - the lossless form browsers and Office prefer.
        #   UnicodeText   - what a terminal's Ctrl+V pastes.
        #   marker        - so this watcher skips its own output.
        $png = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($path))
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetImage($img)
        $data.SetData("PNG", $false, $png)
        $data.SetText($text)
        $data.SetData($MarkerFormat, $false, (New-Object System.IO.MemoryStream(, [byte[]](1))))

        # SetDataObject(data, copy, retryTimes, retryDelay): copy=true keeps
        # the data after this process exits; the retries ride out another app
        # (Snipping Tool, a browser, an IME) briefly holding the clipboard.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
            } catch {
                Write-Log "SetDataObject attempt $attempt FAILED: $_"
                continue
            }
            Start-Sleep -Milliseconds 50
            $readback = ""
            $hasImage = $false
            try {
                $now = [System.Windows.Forms.Clipboard]::GetDataObject()
                if ($now -and $now.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)) {
                    $readback = [string]$now.GetData([System.Windows.Forms.DataFormats]::UnicodeText)
                }
                $hasImage = $now -and $now.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap)
            } catch {}
            if ($readback -eq $text -and $hasImage) {
                Write-Log "SAVED $path (clipboard now holds the image and its path)"
                Write-Host "[$(Get-Date -Format HH:mm:ss)] saved -> $path"
                return $true
            }
            $rbPreview = if ($readback) { $readback.Substring(0, [Math]::Min(80, $readback.Length)) } else { "(empty)" }
            Write-Log "READBACK MISMATCH attempt $attempt expected=$text got=$rbPreview image=$hasImage"
            Start-Sleep -Milliseconds 150
        }
        return $false
    } catch {
        Write-Log "convert FAILED: $_"
        return $false
    } finally {
        if ($img) { $img.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Main loop. STA apartment is required for clipboard access.
# ---------------------------------------------------------------------------

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "Re-launching in STA apartment..."
    $relaunch = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta",
        "-File", "`"$PSCommandPath`"",
        "-OutputDir", "`"$OutputDir`"",
        "-PollMs", $PollMs
    )
    if ($Once) { $relaunch += "-Once" }
    Start-Process powershell.exe -ArgumentList $relaunch -WindowStyle Hidden
    exit
}

if ($Once) {
    if (-not (Test-UnconvertedImage)) {
        Write-Host "No unconverted image on the clipboard."
        exit 1
    }
    if (Convert-ClipboardImage) { exit 0 } else { exit 1 }
}

# One watcher per login session. Two of them used to run at once (a Startup
# shortcut and a scheduled task), racing each other for the clipboard.
$mutex = New-Object System.Threading.Mutex($false, "Local\ScreenshotSnippetsWatcher")
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}
if (-not $owned) {
    Write-Log "another watcher is already running; exiting"
    exit 0
}

Limit-Log
Write-Host "screenshot-snippets watcher running."
Write-Host "  Output directory: $OutputDir"
Write-Host "  Log file:         $LogPath"
Write-Host "Snip an image and switch to a terminal, then press Ctrl+V."
Write-Host "Press Ctrl+C in this window to stop."
Write-Log "watcher started, OutputDir=$OutputDir, PollMs=$PollMs"

$lastSeq = [uint32]0
$pending = $false       # clipboard holds an image we have not converted yet
$failures = 0
$lastSkippedKey = ""
$nextHeartbeat = (Get-Date) + $HeartbeatEvery

while ($true) {
    try {
        $seq = [SnippetsWin32]::GetClipboardSequenceNumber()
        if ($seq -ne $lastSeq) {
            $lastSeq = $seq
            $pending = Test-UnconvertedImage
            $failures = 0
            $lastSkippedKey = ""
        }

        if ($pending) {
            if (Test-IsTerminal) {
                if (Convert-ClipboardImage) {
                    $pending = $false
                    # Our own write bumped the sequence number; do not treat
                    # it as a new clipboard event.
                    $lastSeq = [SnippetsWin32]::GetClipboardSequenceNumber()
                } elseif (++$failures -ge 5) {
                    Write-Log "giving up on this clipboard image after $failures attempts"
                    $pending = $false
                }
            } else {
                # Log once per foreground window, not every tick.
                $skKey = "$(Get-ForegroundProcessName)|$(Get-ForegroundClass)|$(Get-ForegroundTitle)"
                if ($skKey -ne $lastSkippedKey) {
                    $lastSkippedKey = $skKey
                    Write-Log "WAIT image (foreground is not a terminal): $skKey"
                }
            }
        }

        if ((Get-Date) -ge $nextHeartbeat) {
            $nextHeartbeat = (Get-Date) + $HeartbeatEvery
            Limit-Log
            Write-Log "heartbeat pending_image=$pending foreground_proc=$(Get-ForegroundProcessName)"
        }
    } catch {
        Write-Log "ERROR: $_"
        Write-Host "warn: $_"
    }
    Start-Sleep -Milliseconds $PollMs
}
