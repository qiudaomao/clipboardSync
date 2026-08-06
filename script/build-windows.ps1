param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$Runtime = "win-x64",

    [switch]$SelfContained,

    [switch]$StopRunning
)

$ErrorActionPreference = "Stop"

# The script lives in script/; the repo root is one level up.
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Project = Join-Path $Root "win\ClipboardSyncWin\ClipboardSyncWin.csproj"
$ServiceProject = Join-Path $Root "win\ClipboardSyncInputService\ClipboardSyncInputService.csproj"
$Dotnet = Join-Path $Root ".dotnet\dotnet.exe"

if (-not (Test-Path $Dotnet)) {
    throw "Local .NET SDK was not found at: $Dotnet"
}

if (-not (Test-Path $Project)) {
    throw "Project file was not found at: $Project"
}

if (-not (Test-Path $ServiceProject)) {
    throw "Input service project file was not found at: $ServiceProject"
}

$env:DOTNET_CLI_HOME = Join-Path $Root ".dotnet_home"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:APPDATA = Join-Path $Root ".appdata"
$env:LOCALAPPDATA = Join-Path $Root ".localappdata"
$env:NUGET_PACKAGES = Join-Path $Root ".nuget\packages"

if ($StopRunning) {
    Get-Process ClipboardSync -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process ClipboardSyncWin -ErrorAction SilentlyContinue | Stop-Process -Force
}

$selfContainedValue = if ($SelfContained) { "true" } else { "false" }

# Publishes a project and cleans any stale publish output first. Invoke as a statement (not
# `$x = Publish-Project ...`); dotnet's console output flows to the host, so capturing the call
# would fold that text into the return value.
function Publish-Project {
    param(
        [string]$ProjectPath,
        [string]$RuntimeDir
    )

    $publishDir = Join-Path $RuntimeDir "publish"
    if (Test-Path $publishDir) {
        $resolvedPublishDir = (Resolve-Path $publishDir).Path
        $expectedRoot = (Resolve-Path $RuntimeDir).Path
        if (-not $resolvedPublishDir.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unexpected publish directory: $resolvedPublishDir"
        }
        Remove-Item -LiteralPath $resolvedPublishDir -Recurse -Force
    }

    & $Dotnet publish $ProjectPath `
        -c $Configuration `
        -r $Runtime `
        --self-contained $selfContainedValue

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$AppRuntimeDir = Join-Path $Root "win\ClipboardSyncWin\bin\$Configuration\net8.0-windows\$Runtime"
$ServiceRuntimeDir = Join-Path $Root "win\ClipboardSyncInputService\bin\$Configuration\net8.0-windows\$Runtime"
$PublishDir = Join-Path $AppRuntimeDir "publish"

Publish-Project -ProjectPath $Project -RuntimeDir $AppRuntimeDir
# The secure-desktop input service ships alongside the app; the installer registers it as a
# LocalSystem service so injected input can reach the lock screen / UAC desktop.
Publish-Project -ProjectPath $ServiceProject -RuntimeDir $ServiceRuntimeDir

$ExePath = Join-Path $PublishDir "ClipboardSync.exe"

if (Test-Path $ExePath) {
    $Exe = Get-Item $ExePath
    Write-Host ""
    Write-Host "Build succeeded:"
    Write-Host $Exe.FullName
    Write-Host "Updated: $($Exe.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Size: $($Exe.Length) bytes"
}
