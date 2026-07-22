[CmdletBinding()]
param(
    [string]$Version,
    [string]$LocalZip,
    [string]$Sha256,
    [string]$InstallRoot,
    [switch]$NoPathUpdate,
    [string]$Repo = "Ouro-labs/ourocode",
    [string]$ReleaseUrl,
    [string]$Sha256Url,
    [switch]$SkipPrerequisiteCheckForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-Install {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-Install "$Description path was empty."
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Stop-Install "$Description not found: $Path"
    }

    return $resolved.ProviderPath
}

function Get-DefaultInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Stop-Install "LOCALAPPDATA is not set. Pass -InstallRoot to choose an install directory."
    }

    return (Join-Path $env:LOCALAPPDATA "Ourocode")
}

function Get-VersionFromZipName {
    param([string]$ZipPath)

    $name = [System.IO.Path]::GetFileName($ZipPath)
    $match = [regex]::Match($name, '^ourocode-v(.+)-windows-x64\.zip$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Assert-EscriptAvailable {
    param([switch]$SkipForTest)

    if ($SkipForTest) {
        Write-Host "==> skipping escript.exe prerequisite check for installer test"
        return
    }

    $escript = Get-Command escript.exe -ErrorAction SilentlyContinue
    if (-not $escript) {
        Stop-Install @"
Erlang/OTP runtime was not found: escript.exe is not available on PATH.

Ourocode is installed as an Erlang escript and needs Erlang/OTP to run.
Install Erlang/OTP from https://www.erlang.org/downloads, open a new PowerShell
session, confirm `Get-Command escript.exe` succeeds, then rerun this installer.
"@
    }
}

function Get-ReleaseAssetUrl {
    param(
        [string]$Version,
        [string]$Repo,
        [string]$ReleaseUrl
    )

    $assetName = "ourocode-v$Version-windows-x64.zip"
    if ([string]::IsNullOrWhiteSpace($ReleaseUrl)) {
        return "https://github.com/$Repo/releases/download/v$Version/$assetName"
    }

    return $ReleaseUrl
}

function Save-UrlToFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($Url, $Destination)
    }
    finally {
        $client.Dispose()
    }
}

function Read-UrlText {
    param([string]$Url)

    $client = New-Object System.Net.WebClient
    try {
        return $client.DownloadString($Url)
    }
    finally {
        $client.Dispose()
    }
}

function Save-ReleaseZip {
    param(
        [string]$Version,
        [string]$Repo,
        [string]$ReleaseUrl,
        [string]$DestinationDirectory
    )

    $assetName = "ourocode-v$Version-windows-x64.zip"
    $ReleaseUrl = Get-ReleaseAssetUrl -Version $Version -Repo $Repo -ReleaseUrl $ReleaseUrl
    $destination = Join-Path $DestinationDirectory $assetName
    Write-Host "==> downloading $ReleaseUrl"
    Save-UrlToFile -Url $ReleaseUrl -Destination $destination
    return $destination
}

function Get-ExpectedReleaseSha256 {
    param(
        [string]$Version,
        [string]$Repo,
        [string]$ReleaseUrl,
        [string]$Sha256Url
    )

    if (-not [string]::IsNullOrWhiteSpace($Sha256Url)) {
        $checksumUrl = $Sha256Url
    }
    else {
        $checksumUrl = "$(Get-ReleaseAssetUrl -Version $Version -Repo $Repo -ReleaseUrl $ReleaseUrl).sha256"
    }

    Write-Host "==> downloading checksum $checksumUrl"
    $content = Read-UrlText -Url $checksumUrl
    $match = [regex]::Match($content, '(?i)\b[0-9a-f]{64}\b')
    if (-not $match.Success) {
        Stop-Install "Checksum response did not contain a SHA256 value: $checksumUrl"
    }

    return $match.Value
}

function Get-LocalZipSha256 {
    param([string]$ZipPath)

    $checksumPath = "$ZipPath.sha256"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        Stop-Install "Local zip installs require -Sha256 or a sidecar checksum file at $checksumPath."
    }

    $content = Get-Content -LiteralPath $checksumPath -Raw
    $match = [regex]::Match($content, '(?i)\b[0-9a-f]{64}\b')
    if (-not $match.Success) {
        Stop-Install "Checksum file did not contain a SHA256 value: $checksumPath"
    }

    return $match.Value
}

function Assert-ZipHash {
    param(
        [string]$ZipPath,
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return
    }

    $actual = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($actual -ne $expected) {
        Stop-Install "SHA256 mismatch for $ZipPath. Expected $expected but got $actual."
    }
}

function Expand-ReleaseZip {
    param(
        [string]$ZipPath,
        [string]$DestinationDirectory
    )

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestinationDirectory -Force

    $entrypoint = Get-ChildItem -LiteralPath $DestinationDirectory -Recurse -Force -File |
        Where-Object { $_.Name -ceq "ourocode" } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if (-not $entrypoint) {
        Stop-Install "Release zip did not contain an 'ourocode' escript."
    }

    return $entrypoint.Directory.FullName
}

function Copy-ReleaseRoot {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
    Get-ChildItem -LiteralPath $SourceRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationRoot -Recurse -Force
    }

    $installedOurocode = Join-Path $DestinationRoot "ourocode"
    if (-not (Test-Path -LiteralPath $installedOurocode -PathType Leaf)) {
        Stop-Install "Install staging failed: missing $installedOurocode"
    }
}

function Move-StagedInstall {
    param(
        [string]$StageRoot,
        [string]$InstallDirectory
    )

    $parent = Split-Path -Parent $InstallDirectory
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $backup = $null
    if (Test-Path -LiteralPath $InstallDirectory) {
        $backup = "$InstallDirectory.previous-$([System.Guid]::NewGuid().ToString('N'))"
        Move-Item -LiteralPath $InstallDirectory -Destination $backup
    }

    try {
        Move-Item -LiteralPath $StageRoot -Destination $InstallDirectory
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    }
    catch {
        if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $InstallDirectory)) {
            Move-Item -LiteralPath $backup -Destination $InstallDirectory
        }
        throw
    }
}

function Write-CmdLauncher {
    param(
        [string]$LauncherPath,
        [string]$InstallDirectory
    )

    $installedOurocode = Join-Path $InstallDirectory "ourocode"
    $installedTty = Join-Path (Join-Path $InstallDirectory "bin") "ourocode_tty.exe"
    $content = @"
@echo off
setlocal
if exist "$installedTty" set "OUROCODE_TTY=$installedTty"
escript.exe "$installedOurocode" %*
exit /b %ERRORLEVEL%
"@

    $launcherDirectory = Split-Path -Parent $LauncherPath
    New-Item -ItemType Directory -Force -Path $launcherDirectory | Out-Null
    Set-Content -LiteralPath $LauncherPath -Value $content -Encoding ASCII
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

function Add-UserPathOnce {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $entries = $current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $targetKey = ConvertTo-PathKey $Directory
    $deduped = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($entry in $entries) {
        $key = ConvertTo-PathKey $entry
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        if ($key -eq $targetKey) {
            continue
        }
        if ($seen.Add($key)) {
            $deduped.Add($entry.Trim())
        }
    }

    $deduped.Add($Directory)
    $newPath = [string]::Join(';', $deduped)
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    if (($env:Path -split ';' | ForEach-Object { ConvertTo-PathKey $_ }) -notcontains $targetKey) {
        $env:Path = "$Directory;$env:Path"
    }
}

Assert-EscriptAvailable -SkipForTest:$SkipPrerequisiteCheckForTest

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ourocode-install-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $zipPath = $null
    if (-not [string]::IsNullOrWhiteSpace($LocalZip)) {
        $zipPath = Resolve-ExistingFile -Path $LocalZip -Description "Local zip"
        if ([string]::IsNullOrWhiteSpace($Sha256)) {
            $Sha256 = Get-LocalZipSha256 -ZipPath $zipPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        if ($zipPath) {
            $Version = Get-VersionFromZipName -ZipPath $zipPath
        }
        if ([string]::IsNullOrWhiteSpace($Version) -and -not [string]::IsNullOrWhiteSpace($env:OUROCODE_VERSION)) {
            $Version = $env:OUROCODE_VERSION
        }
        if ([string]::IsNullOrWhiteSpace($Version)) {
            $Version = "0.1.13"
        }
    }

    if (-not $zipPath) {
        $zipPath = Save-ReleaseZip -Version $Version -Repo $Repo -ReleaseUrl $ReleaseUrl -DestinationDirectory $tempRoot
        if ([string]::IsNullOrWhiteSpace($Sha256)) {
            $Sha256 = Get-ExpectedReleaseSha256 -Version $Version -Repo $Repo -ReleaseUrl $ReleaseUrl -Sha256Url $Sha256Url
        }
    }

    $root = $InstallRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-DefaultInstallRoot
    }
    $root = [System.IO.Path]::GetFullPath($root)

    $installDirectory = Join-Path $root $Version
    $launcherDirectory = Join-Path $root "bin"
    $launcherPath = Join-Path $launcherDirectory "ourocode.cmd"
    $expanded = Join-Path $tempRoot "expanded"
    $stage = Join-Path $tempRoot "stage"

    Write-Host "==> ourocode install"
    Write-Host "==> version: $Version"
    Write-Host "==> zip: $zipPath"
    Assert-ZipHash -ZipPath $zipPath -ExpectedSha256 $Sha256

    $releaseRoot = Expand-ReleaseZip -ZipPath $zipPath -DestinationDirectory $expanded
    Copy-ReleaseRoot -SourceRoot $releaseRoot -DestinationRoot $stage
    Move-StagedInstall -StageRoot $stage -InstallDirectory $installDirectory
    Write-CmdLauncher -LauncherPath $launcherPath -InstallDirectory $installDirectory

    if ($NoPathUpdate) {
        Write-Host "==> PATH update skipped (-NoPathUpdate)"
    }
    else {
        Add-UserPathOnce -Directory $launcherDirectory
        Write-Host "==> added to user PATH: $launcherDirectory"
        Write-Host "    Open a new PowerShell or Command Prompt session if 'ourocode' is not found."
    }

    Write-Host ""
    Write-Host "==> ready"
    Write-Host "  installed: $installDirectory"
    Write-Host "  command:   $launcherPath"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
