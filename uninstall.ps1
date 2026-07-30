#requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the screenshot-snippets clipboard watcher.

.DESCRIPTION
    This script:
      1. Kills any running screenshot-snippets PowerShell process.
      2. Removes the Startup shortcut.
      3. Removes the installed files under %USERPROFILE%\.screenshot-snippets.

    Your saved PNG captures are NOT deleted unless you pass -DeleteCaptures.
#>
[CmdletBinding()]
param(
    [switch]$DeleteCaptures
)

$ErrorActionPreference = "Stop"

$installDir = Join-Path $env:USERPROFILE ".screenshot-snippets"
$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupFolder "screenshot-snippets.lnk"

# Kill running watcher processes
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -match "screenshot-snippets" } |
    ForEach-Object {
        Write-Output "Stopping process PID $($_.ProcessId)..."
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

# Remove startup shortcut
if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Write-Output "Removed startup shortcut: $shortcutPath"
}

# Remove install directory
if (Test-Path $installDir) {
    Remove-Item $installDir -Recurse -Force
    Write-Output "Removed install directory: $installDir"
}

if ($DeleteCaptures) {
    $defaultCaptureDir = $env:TEMP
    $captures = Get-ChildItem -Path $defaultCaptureDir -Filter "clip-*.png" -ErrorAction SilentlyContinue
    if ($captures) {
        $captures | Remove-Item -Force
        Write-Output "Deleted $($captures.Count) capture(s) from $defaultCaptureDir"
    }
}

Write-Output "screenshot-snippets uninstalled."
