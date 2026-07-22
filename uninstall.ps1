[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$Version,
    [switch]$KeepPath,
    [switch]$AllVersions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-Uninstall {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Get-DefaultInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Stop-Uninstall "LOCALAPPDATA is not set. Pass -InstallRoot to choose an install directory."
    }

    return (Join-Path $env:LOCALAPPDATA "Ourocode")
}

function ConvertTo-PathKey {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $trimmed = $Path.Trim().Trim('"')
    try {
        $full = [System.IO.Path]::GetFullPath($trimmed)
    }
    catch {
        $full = $trimmed
    }

    return $full.TrimEnd('\').ToLowerInvariant()
}

function Remove-UserPathEntry {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($current)) {
        return $false
    }

    $targetKey = ConvertTo-PathKey $Directory
    $kept = New-Object System.Collections.Generic.List[string]
    $changed = $false

    foreach ($entry in ($current -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $trimmed = $entry.Trim()
        if ((ConvertTo-PathKey $trimmed) -eq $targetKey) {
            $changed = $true
            continue
        }

        $kept.Add($trimmed)
    }

    if ($changed) {
        [Environment]::SetEnvironmentVariable("Path", [string]::Join(';', $kept), "User")
        $env:Path = [string]::Join(
            ';',
            @($env:Path -split ';' | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and (ConvertTo-PathKey $_) -ne $targetKey
            })
        )
    }

    return $changed
}

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return $true
    }

    return $false
}

function Assert-SafeInstallRoot {
    param([string]$Path)

    $pathKey = ConvertTo-PathKey $Path
    $driveRootKey = ConvertTo-PathKey ([System.IO.Path]::GetPathRoot($Path))
    if ($pathKey -eq $driveRootKey) {
        Stop-Uninstall "Refusing to uninstall from a drive root: $Path"
    }

    $blockedRoots = @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:SystemRoot,
        $env:TEMP,
        $env:TMP
    )

    foreach ($blockedRoot in $blockedRoots) {
        if ([string]::IsNullOrWhiteSpace($blockedRoot)) {
            continue
        }

        if ($pathKey -eq (ConvertTo-PathKey $blockedRoot)) {
            Stop-Uninstall "Refusing to uninstall from a broad system or profile directory: $Path"
        }
    }
}

if ($AllVersions -and -not [string]::IsNullOrWhiteSpace($Version)) {
    Stop-Uninstall "Use either -Version or -AllVersions, not both."
}

$root = $InstallRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Get-DefaultInstallRoot
}
$root = [System.IO.Path]::GetFullPath($root)
Assert-SafeInstallRoot -Path $root

$launcherDirectory = Join-Path $root "bin"
$launcherPath = Join-Path $launcherDirectory "ourocode.cmd"

Write-Host "==> ourocode uninstall"
Write-Host "==> root: $root"

if (-not $KeepPath) {
    if (Remove-UserPathEntry -Directory $launcherDirectory) {
        Write-Host "==> removed from user PATH: $launcherDirectory"
        Write-Host "    Open a new PowerShell or Command Prompt session if PATH still shows the old entry."
    }
    else {
        Write-Host "==> user PATH did not contain: $launcherDirectory"
    }
}
else {
    Write-Host "==> PATH update skipped (-KeepPath)"
}

if (Remove-IfExists -Path $launcherPath) {
    Write-Host "==> removed launcher: $launcherPath"
}
else {
    Write-Host "==> launcher not present: $launcherPath"
}

if ($AllVersions) {
    $removedRoot = Remove-IfExists -Path $root
    if ($removedRoot) {
        Write-Host "==> removed install root: $root"
    }
    else {
        Write-Host "==> install root not present: $root"
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($Version)) {
    $versionDirectory = Join-Path $root $Version
    if (Remove-IfExists -Path $versionDirectory) {
        Write-Host "==> removed version: $versionDirectory"
    }
    else {
        Write-Host "==> version not present: $versionDirectory"
    }

    if ((Test-Path -LiteralPath $launcherDirectory) -and -not (Get-ChildItem -LiteralPath $launcherDirectory -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Item -LiteralPath $launcherDirectory -Force
        Write-Host "==> removed empty launcher directory: $launcherDirectory"
    }
}
else {
    Write-Host "==> version directories left in place; pass -Version <version> or -AllVersions to remove them."
    if ((Test-Path -LiteralPath $launcherDirectory) -and -not (Get-ChildItem -LiteralPath $launcherDirectory -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Item -LiteralPath $launcherDirectory -Force
        Write-Host "==> removed empty launcher directory: $launcherDirectory"
    }
}

Write-Host ""
Write-Host "==> removed"
