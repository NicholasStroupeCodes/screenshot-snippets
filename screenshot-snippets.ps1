#requires -Version 5.1
<#
.SYNOPSIS
    Screenshot-snippets — clipboard image watcher for Windows terminals.

.DESCRIPTION
    Runs in the background and polls the clipboard. When you snip a screenshot
    (Win+Shift+S, Snipping Tool, PrintScreen), the image lands on the Windows
    clipboard. If the foreground window is a terminal, this script:

      1. Saves the image to a PNG file in the configured output directory.
      2. Replaces the clipboard contents with the quoted file path as text.

    Press Ctrl+V in the terminal and the path appears. Press Enter and your
    CLI (Claude Code, Kimi Code, etc.) can read the image file.

    If the foreground window is NOT a terminal (Slack, Discord, browser, etc.),
    the clipboard image is left alone so normal image paste keeps working.

.PARAMETER OutputDir
    Directory where captured PNGs are saved. Defaults to the system TEMP folder.

.PARAMETER PollMs
    Clipboard poll interval in milliseconds. Defaults to 250.

.EXAMPLE
    .\screenshot-snippets.ps1

.EXAMPLE
    .\screenshot-snippets.ps1 -OutputDir "$env:USERPROFILE\Pictures\Snips" -PollMs 200
#>
[CmdletBinding()]
param(
    [string]$OutputDir = $env:SCREENSHOT_SNIPPETS_DIR,
    [int]$PollMs = 250
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
# P/Invoke for foreground-window detection. Without this we'd swap clipboard
# images in EVERY app, which breaks pasting into Slack / Cursor / Discord.
# ---------------------------------------------------------------------------

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

function Get-ForegroundClass {
    $hwnd = [Win32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 256
    [Win32]::GetClassName($hwnd, $sb, 256) | Out-Null
    return $sb.ToString()
}

function Get-ForegroundTitle {
    $hwnd = [Win32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 512
    [Win32]::GetWindowText($hwnd, $sb, 512) | Out-Null
    return $sb.ToString()
}

function Get-ForegroundProcessName {
    $hwnd = [Win32]::GetForegroundWindow()
    $procId = 0
    [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
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
    # Electron-based editors share Chrome_WidgetWin_1 — only trust when
    # the title strongly suggests a terminal context.
    if ($cls -eq "Chrome_WidgetWin_1") {
        $title = Get-ForegroundTitle
        if ($title -match "(Cursor|Visual Studio Code|Terminal|PowerShell|cmd|Bash|claude|kimi)") {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Clipboard polling. We hash a small thumbnail of each new image so we don't
# re-save the same screenshot if the user lingers without doing anything.
# ---------------------------------------------------------------------------

$lastSavedHash = ""
$lastSkippedKey = ""

function Get-ImageHash([System.Drawing.Image]$img) {
    # Content fingerprint: dimensions + 9 sampled pixels (corners, edge
    # midpoints, center). Dimensions alone aren't enough — two different
    # snips of the same screen region have identical width/height, so a
    # dimension-only hash makes the watcher skip every "new" snip after
    # the first.
    try {
        $bmp = [System.Drawing.Bitmap]$img
        $w = $bmp.Width
        $h = $bmp.Height
        $mx = [int]($w / 2)
        $my = [int]($h / 2)
        $rx = [Math]::Max(0, $w - 1)
        $ry = [Math]::Max(0, $h - 1)
        $samples = @(
            $bmp.GetPixel(0, 0).ToArgb(),
            $bmp.GetPixel($mx, 0).ToArgb(),
            $bmp.GetPixel($rx, 0).ToArgb(),
            $bmp.GetPixel(0, $my).ToArgb(),
            $bmp.GetPixel($mx, $my).ToArgb(),
            $bmp.GetPixel($rx, $my).ToArgb(),
            $bmp.GetPixel(0, $ry).ToArgb(),
            $bmp.GetPixel($mx, $ry).ToArgb(),
            $bmp.GetPixel($rx, $ry).ToArgb()
        )
        return "{0}x{1}:{2}" -f $w, $h, ($samples -join ",")
    } catch {
        return "{0}x{1}" -f $img.Width, $img.Height
    }
}

function Write-Log([string]$msg) {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Invoke-OnClipboardImage {
    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
        # Clipboard no longer holds an image (we swapped to path text, or
        # user copied something else). Reset dedup so the next image
        # session is treated as fresh, even if its content fingerprint
        # happens to match a previously-saved snip.
        $script:lastSavedHash = ""
        $script:lastSkippedKey = ""
        return
    }
    if (-not (Test-IsTerminal)) {
        # Image is on clipboard but foreground isn't a known terminal.
        # Dedupe by foreground-window IDENTITY (proc|class|title), NOT
        # image content. Calling GetImage() in this hot path leaks GDI
        # bitmaps when an image lingers on the clipboard for a long time
        # (~1.5h killed the watcher silently).
        $skProc = Get-ForegroundProcessName
        $skCls = Get-ForegroundClass
        $skTitle = Get-ForegroundTitle
        $skKey = "$skProc|$skCls|$skTitle"
        if ($skKey -ne $script:lastSkippedKey) {
            $script:lastSkippedKey = $skKey
            Write-Log "SKIP image (not terminal): proc='$skProc' class='$skCls' title='$skTitle'"
        }
        return
    }

    $img = $null
    try {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -eq $img) { return }

        $hash = Get-ImageHash $img
        if ($hash -eq $script:lastSavedHash) { return }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $path = Join-Path $OutputDir "clip-$stamp.png"
        $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

        # Replace clipboard with the path so the user's next paste in
        # the terminal pastes the path as text.
        #
        # SetDataObject(data, copy, retryTimes, retryDelay) is the
        # correct overload: retries on OpenClipboard failure (which
        # happens when another app -- Snipping Tool, browser, IME --
        # is currently holding the clipboard lock). Without retry the
        # set silently fails ~30% of the time on busy systems.
        #
        # copy=true makes the data persist after this process exits.
        # 10 retries x 100ms = 1 second of patience, more than enough
        # for normal clipboard contention to clear.
        $text = "`"$path`""
        $writeOk = $false
        try {
            [System.Windows.Forms.Clipboard]::SetDataObject($text, $true, 10, 100)
            $writeOk = $true
        } catch {
            Write-Log "SetDataObject FAILED: $_"
        }

        # Verify the write stuck -- read it back and compare.
        # If our text isn't there, the OS probably let the snipping-
        # tool format win the race; retry once more after a beat.
        if ($writeOk) {
            Start-Sleep -Milliseconds 50
            $readback = ""
            try {
                if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                    $readback = [System.Windows.Forms.Clipboard]::GetText()
                }
            } catch {}
            if ($readback -ne $text) {
                $rbPreview = if ($readback) { $readback.Substring(0, [Math]::Min(80, $readback.Length)) } else { "(empty)" }
                Write-Log "READBACK MISMATCH expected=$text got=$rbPreview -- retrying"
                Start-Sleep -Milliseconds 150
                try {
                    [System.Windows.Forms.Clipboard]::SetDataObject($text, $true, 10, 100)
                } catch {
                    Write-Log "second SetDataObject FAILED: $_"
                }
            } else {
                Write-Log "READBACK OK (clipboard now contains the path)"
            }
        }

        $script:lastSavedHash = $hash
        Write-Log "SAVED $path (foreground was a terminal)"
        Write-Host "[$(Get-Date -Format HH:mm:ss)] saved -> $path"
    } finally {
        if ($img) { $img.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Main loop. STA apartment is required for clipboard access.
# ---------------------------------------------------------------------------

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "Re-launching in STA apartment..."
    Start-Process powershell.exe -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta",
        "-File", "`"$PSCommandPath`"",
        "-OutputDir", "`"$OutputDir`"",
        "-PollMs", $PollMs
    ) -WindowStyle Hidden
    exit
}

Write-Host "screenshot-snippets watcher running."
Write-Host "  Output directory: $OutputDir"
Write-Host "  Log file:         $LogPath"
Write-Host "Snip an image and switch to a terminal, then press Ctrl+V."
Write-Host "Press Ctrl+C in this window to stop."
Write-Log "watcher started, PID=$PID, OutputDir=$OutputDir, PollMs=$PollMs"

# Heartbeat every 40 ticks (~10s with default 250ms poll) so we can confirm
# the loop is alive even when no image is on the clipboard.
$tick = 0
while ($true) {
    try {
        Invoke-OnClipboardImage
        $tick++
        if ($tick % 40 -eq 0) {
            $hasImg = [System.Windows.Forms.Clipboard]::ContainsImage()
            $proc = Get-ForegroundProcessName
            $isTerm = Test-IsTerminal
            Write-Log "heartbeat tick=$tick clipboard_has_image=$hasImg foreground_proc=$proc is_terminal=$isTerm"
        }
    } catch {
        Write-Log "ERROR: $_"
        Write-Host "warn: $_"
    }
    Start-Sleep -Milliseconds $PollMs
}
