param(
    [string]$Version = "0.1.1",

    [string]$ReleaseVersion = "",

    [string]$Runtime = "win-x64",

    [switch]$SelfContained,

    [switch]$StopRunning
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InnoScript = Join-Path $Root "win\installer\ClipboardSyncWin.iss"

if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) {
    $ReleaseVersion = "v$Version"
}

$isccCommand = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
$isccPath = if ($isccCommand) { $isccCommand.Source } else { $null }
if (-not $isccPath) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $isccPath = $candidate
            break
        }
    }
}

if (-not $isccPath) {
    throw "Inno Setup 6 compiler was not found. Install Inno Setup 6 or add ISCC.exe to PATH."
}

& (Join-Path $Root "build-windows.ps1") -Configuration Release -Runtime $Runtime -SelfContained:$SelfContained -StopRunning:$StopRunning
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$env:CLIPBOARD_SYNC_VERSION = $Version
$env:CLIPBOARD_SYNC_RELEASE_VERSION = $ReleaseVersion
& $isccPath $InnoScript

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$installer = Join-Path $Root "artifacts\windows\ClipboardSyncSetup-$ReleaseVersion.exe"
if (Test-Path $installer) {
    $item = Get-Item $installer
    Write-Host ""
    Write-Host "Installer built:"
    Write-Host $item.FullName
    Write-Host "Size: $($item.Length) bytes"
}
