param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$Runtime = "win-x64",

    [switch]$SelfContained,

    [switch]$StopRunning
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Join-Path $Root "win\ClipboardSyncWin\ClipboardSyncWin.csproj"
$Dotnet = Join-Path $Root ".dotnet\dotnet.exe"

if (-not (Test-Path $Dotnet)) {
    throw "Local .NET SDK was not found at: $Dotnet"
}

if (-not (Test-Path $Project)) {
    throw "Project file was not found at: $Project"
}

$env:DOTNET_CLI_HOME = Join-Path $Root ".dotnet_home"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:APPDATA = Join-Path $Root ".appdata"
$env:LOCALAPPDATA = Join-Path $Root ".localappdata"
$env:NUGET_PACKAGES = Join-Path $Root ".nuget\packages"

if ($StopRunning) {
    Get-Process ClipboardSyncWin -ErrorAction SilentlyContinue | Stop-Process -Force
}

$selfContainedValue = if ($SelfContained) { "true" } else { "false" }

& $Dotnet publish $Project `
    -c $Configuration `
    -r $Runtime `
    --self-contained $selfContainedValue

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$ExePath = Join-Path $Root "win\ClipboardSyncWin\bin\$Configuration\net8.0-windows\$Runtime\publish\ClipboardSyncWin.exe"

if (Test-Path $ExePath) {
    $Exe = Get-Item $ExePath
    Write-Host ""
    Write-Host "Build succeeded:"
    Write-Host $Exe.FullName
    Write-Host "Updated: $($Exe.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Size: $($Exe.Length) bytes"
}
