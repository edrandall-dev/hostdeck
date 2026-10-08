#Requires -Version 5.1
<#
Install HostDeck for Windows for the current user, or remove it.

Usage:
  powershell -ExecutionPolicy Bypass -File windows\Install.ps1                 Install, or update after git pull.
  powershell -ExecutionPolicy Bypass -File windows\Install.ps1 -StartAtLogin   Also start HostDeck when you sign in.
  powershell -ExecutionPolicy Bypass -File windows\Install.ps1 -Uninstall      Remove the app and its shortcuts.

The install copies HostDeck.ps1 to %LOCALAPPDATA%\Programs\HostDeck and adds HostDeck to the Start menu.
It needs no administrator rights. Your hosts are in %APPDATA%\HostDeck. Install and Uninstall do not change them.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$StartAtLogin,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\HostDeck'),
    [string]$ShortcutDir = [Environment]::GetFolderPath('Programs'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup')
)
$ErrorActionPreference = 'Stop'

$script = Join-Path $InstallDir 'HostDeck.ps1'
$icon = Join-Path $InstallDir 'HostDeck.ico'
$shortcut = Join-Path $ShortcutDir 'HostDeck.lnk'
$startup = Join-Path $StartupDir 'HostDeck.lnk'

if ($Uninstall) {
    foreach ($p in @($shortcut, $startup)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p; "Removed $p" }
    }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse; "Removed $InstallDir" }
    "Your hosts are still in $(Join-Path $env:APPDATA 'HostDeck'). To remove them too, delete that folder."
    'If HostDeck is running, right-click its icon in the notification area and choose Exit HostDeck.'
    return
}

$source = Join-Path $PSScriptRoot 'HostDeck.ps1'
if (-not (Test-Path -LiteralPath $source)) { throw "Cannot find $source. Run Install.ps1 from the windows folder of the repository." }

if (-not (Test-Path -LiteralPath $InstallDir)) { [void](New-Item -ItemType Directory -Path $InstallDir) }
Copy-Item -LiteralPath $source -Destination $script -Force
# A file from a downloaded zip has a mark that makes PowerShell ask before it runs the file.
Unblock-File -LiteralPath $script
& { . $source -NoGui; Save-HDIconFile $icon }

# conhost --headless starts PowerShell with no console window, also when Windows Terminal is the default
# terminal. -WindowStyle Hidden does not hide a Windows Terminal window. Older Windows has no --headless.
$powershell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$script`""
if ([Environment]::OSVersion.Version.Build -ge 19041) {
    $target = Join-Path $env:windir 'System32\conhost.exe'
    $arguments = "--headless `"$powershell`" $arguments"
} else {
    $target = $powershell
    $arguments = "-WindowStyle Hidden $arguments"
}

function New-HostDeckShortcut([string]$path) {
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($path)
    $s.TargetPath = $target
    $s.Arguments = $arguments
    $s.WorkingDirectory = $InstallDir
    $s.IconLocation = "$icon,0"
    $s.Description = 'Check, wake and connect to the hosts on your network'
    $s.WindowStyle = 7
    $s.Save()
}

New-HostDeckShortcut $shortcut
"Installed HostDeck in $InstallDir"
"Added HostDeck to the Start menu: $shortcut"
if ($StartAtLogin) {
    New-HostDeckShortcut $startup
    "HostDeck starts when you sign in: $startup"
}
'If HostDeck is running, exit it and start it again to use the new version.'
