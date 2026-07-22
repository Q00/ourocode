[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDir = "dist",
    [string]$PrebuiltRoot,
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$WindowsTarget = "x86_64-pc-windows-msvc"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $RepoRoot $Path)
}

function Get-ProjectVersion {
    $MixFile = Join-Path $RepoRoot "mix.exs"
    if (-not (Test-Path -LiteralPath $MixFile)) {
        throw "Version was not provided and mix.exs was not found."
    }

    $Match = Select-String -Path $MixFile -Pattern 'version:\s*"([^"]+)"' | Select-Object -First 1
    if ($null -eq $Match) {
        throw "Version was not provided and no version entry was found in mix.exs."
    }

    return $Match.Matches[0].Groups[1].Value
}

function Require-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )

    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $Command) {
        throw "Missing prerequisite '$Name'. $InstallHint"
    }

    Write-Host ("  {0}: {1}" -f $Name, $Command.Source)
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Assert-NormalBuildPrerequisites {
    Write-Step "checking Windows release build prerequisites"
    Require-Command "git" "Install Git for Windows and open a new PowerShell session."
    Require-Command "erl" "Install Erlang/OTP and ensure erl.exe is on PATH."
    Require-Command "elixir" "Install Elixir and ensure elixir.exe is on PATH."
    Require-Command "mix" "Install Elixir/Mix and ensure mix.bat is on PATH."
    Require-Command "cargo" "Install the Rust stable MSVC toolchain and ensure cargo.exe is on PATH."
    Require-Command "rustc" "Install the Rust stable MSVC toolchain and ensure rustc.exe is on PATH."

    $RustInfo = & rustc -vV
    if ($LASTEXITCODE -ne 0) {
        throw "rustc -vV failed with exit code $LASTEXITCODE."
    }

    $HostLine = $RustInfo | Where-Object { $_ -like "host:*" } | Select-Object -First 1
    if ($HostLine -notlike "*$WindowsTarget*") {
        throw "Rust host toolchain must be $WindowsTarget for this package script. Current ${HostLine}. Install with: rustup toolchain install stable-$WindowsTarget"
    }

    $Rustup = Get-Command "rustup" -ErrorAction SilentlyContinue
    if ($null -ne $Rustup) {
        $InstalledTargets = & rustup target list --installed
        if ($LASTEXITCODE -ne 0) {
            throw "rustup target list --installed failed with exit code $LASTEXITCODE."
        }
        if ($InstalledTargets -notcontains $WindowsTarget) {
            throw "Missing Rust target $WindowsTarget. Install with: rustup target add $WindowsTarget"
        }
        Write-Host "  rust target: $WindowsTarget"
    } else {
        Write-Host "  rust target: rustup not found; using rustc host $WindowsTarget"
    }
}

function Assert-RequiredFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing package input: $Description at $Path"
    }
}

function New-WindowsLaunchers {
    param([string]$BinDir)

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

    $CmdPath = Join-Path $BinDir "ourocode.cmd"
    $CmdContent = @(
        "@echo off",
        "setlocal",
        'set "SCRIPT_DIR=%~dp0"',
        'set "ROOT_DIR=%SCRIPT_DIR%.."',
        'if exist "%ROOT_DIR%\bin\ourocode_tty.exe" set "OUROCODE_TTY=%ROOT_DIR%\bin\ourocode_tty.exe"',
        'escript.exe "%ROOT_DIR%\ourocode" %*',
        "exit /b %ERRORLEVEL%"
    )
    Set-Content -Path $CmdPath -Value $CmdContent -Encoding ASCII

    $Ps1Path = Join-Path $BinDir "ourocode.ps1"
    $Ps1Content = @(
        '$ErrorActionPreference = "Stop"',
        '$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path',
        '$rootDir = Resolve-Path (Join-Path $scriptDir "..")',
        '$tty = Join-Path $rootDir "bin\ourocode_tty.exe"',
        'if (Test-Path -LiteralPath $tty) { $env:OUROCODE_TTY = $tty }',
        '& escript.exe (Join-Path $rootDir "ourocode") @args',
        'exit $LASTEXITCODE'
    )
    Set-Content -Path $Ps1Path -Value $Ps1Content -Encoding ASCII
}

function Copy-PackageInputs {
    param(
        [string]$SourceRoot,
        [string]$PackageRoot,
        [bool]$IncludeBuiltHelper
    )

    Assert-RequiredFile (Join-Path $SourceRoot "ourocode") "escript"
    Assert-RequiredFile (Join-Path $SourceRoot "install.ps1") "PowerShell installer"
    Assert-RequiredFile (Join-Path $SourceRoot "uninstall.ps1") "PowerShell uninstaller"
    Assert-RequiredFile (Join-Path $SourceRoot "README.md") "README"

    Copy-Item -LiteralPath (Join-Path $SourceRoot "ourocode") -Destination (Join-Path $PackageRoot "ourocode") -Force
    Copy-Item -LiteralPath (Join-Path $SourceRoot "install.ps1") -Destination (Join-Path $PackageRoot "install.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceRoot "uninstall.ps1") -Destination (Join-Path $PackageRoot "uninstall.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceRoot "README.md") -Destination (Join-Path $PackageRoot "README.md") -Force

    $BinDir = Join-Path $PackageRoot "bin"
    New-WindowsLaunchers -BinDir $BinDir

    $PrebuiltHelper = Join-Path $SourceRoot "bin\ourocode_tty.exe"
    if (Test-Path -LiteralPath $PrebuiltHelper -PathType Leaf) {
        Copy-Item -LiteralPath $PrebuiltHelper -Destination (Join-Path $BinDir "ourocode_tty.exe") -Force
        Write-Host "  helper: included prebuilt bin\ourocode_tty.exe"
        Copy-BuiltLauncher -PackageRoot $PackageRoot -IncludeBuiltHelper $IncludeBuiltHelper
        return
    }

    if ($IncludeBuiltHelper) {
        $BuiltHelper = Join-Path $RepoRoot "rust\ourocode_ipc\target\release\ourocode_tty.exe"
        Assert-RequiredFile $BuiltHelper "built Windows TTY helper"
        Copy-Item -LiteralPath $BuiltHelper -Destination (Join-Path $BinDir "ourocode_tty.exe") -Force
        Write-Host "  helper: included built bin\ourocode_tty.exe"
        Copy-BuiltLauncher -PackageRoot $PackageRoot -IncludeBuiltHelper $IncludeBuiltHelper
    } else {
        Write-Host "  helper: bin\ourocode_tty.exe not present; package will omit it"
    }
}

function Copy-BuiltLauncher {
    param(
        [string]$PackageRoot,
        [bool]$IncludeBuiltHelper
    )

    if (-not $IncludeBuiltHelper) {
        return
    }

    $BuiltLauncher = Join-Path $RepoRoot "rust\ourocode_ipc\target\release\ourocode.exe"
    Assert-RequiredFile $BuiltLauncher "built Windows launcher"
    Copy-Item -LiteralPath $BuiltLauncher -Destination (Join-Path $PackageRoot "ourocode.exe") -Force
    Write-Host "  launcher: included built ourocode.exe"
}

try {
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = Get-ProjectVersion
    }

    if ($Configuration -ne "Release") {
        throw "Unsupported build configuration '$Configuration'. Windows release packaging currently supports only Release."
    }

    if ($Version -match '[\\/:*?"<>|]') {
        throw "Version contains characters that are invalid for a Windows file name: $Version"
    }

    $OutputRoot = Resolve-RepoPath $OutputDir
    $PackageName = "ourocode-v$Version-windows-x64"
    $StageParent = Join-Path $OutputRoot "_stage"
    $PackageRoot = Join-Path $StageParent $PackageName
    $ZipPath = Join-Path $OutputRoot "$PackageName.zip"
    $ShaPath = "$ZipPath.sha256"

    Write-Step "packaging $PackageName"
    Write-Host "  configuration: $Configuration"
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    if (Test-Path -LiteralPath $PackageRoot) {
        Remove-Item -LiteralPath $PackageRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    if (Test-Path -LiteralPath $ShaPath) {
        Remove-Item -LiteralPath $ShaPath -Force
    }
    New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null

    Push-Location $RepoRoot
    try {
        if (-not [string]::IsNullOrWhiteSpace($PrebuiltRoot)) {
            $ResolvedPrebuiltRoot = Resolve-RepoPath $PrebuiltRoot
            if (-not (Test-Path -LiteralPath $ResolvedPrebuiltRoot -PathType Container)) {
                throw "PrebuiltRoot was provided but does not exist: $ResolvedPrebuiltRoot"
            }
            Write-Step "using prebuilt fixture root $ResolvedPrebuiltRoot"
            Copy-PackageInputs -SourceRoot $ResolvedPrebuiltRoot -PackageRoot $PackageRoot -IncludeBuiltHelper $false
        } else {
            Assert-NormalBuildPrerequisites
            Assert-RequiredFile (Join-Path $RepoRoot "install.ps1") "PowerShell installer"
            Assert-RequiredFile (Join-Path $RepoRoot "uninstall.ps1") "PowerShell uninstaller"
            Assert-RequiredFile (Join-Path $RepoRoot "README.md") "README"

            Write-Step "building Rust helper"
            Invoke-Checked "cargo" @("build", "--release", "--manifest-path", ".\rust\ourocode_ipc\Cargo.toml", "--bin", "ourocode_tty")

            Write-Step "building Windows launcher"
            Invoke-Checked "cargo" @("build", "--release", "--manifest-path", ".\rust\ourocode_ipc\Cargo.toml", "--bin", "ourocode")

            Write-Step "building Elixir escript"
            Invoke-Checked "mix" @("escript.build")

            Copy-PackageInputs -SourceRoot $RepoRoot -PackageRoot $PackageRoot -IncludeBuiltHelper $true
        }
    } finally {
        Pop-Location
    }

    Write-Step "creating zip"
    Compress-Archive -Path $PackageRoot -DestinationPath $ZipPath -Force

    Write-Step "writing SHA256"
    $Hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
    "{0}  {1}" -f $Hash.Hash.ToLowerInvariant(), (Split-Path -Leaf $ZipPath) | Set-Content -Path $ShaPath -Encoding ASCII

    if (Test-Path -LiteralPath $StageParent) {
        Remove-Item -LiteralPath $StageParent -Recurse -Force
    }

    Write-Step "release ready"
    Write-Host "  $ZipPath"
    Write-Host "  $ShaPath"
} catch {
    if ((Get-Variable -Name StageParent -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $StageParent)) {
        Remove-Item -LiteralPath $StageParent -Recurse -Force
    }
    Write-Error $_.Exception.Message
    exit 1
}
