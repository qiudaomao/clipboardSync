# Releasing a Windows Update

> Prefer **[release_all.md](release_all.md)** when shipping macOS + Windows + Linux together.
> This file is the Windows-only deep dive (NetSparkle, Inno Setup, appcast generation).

Steps to cut a Windows release and publish it through NetSparkle auto-update.

Release artifacts and `win-appcast.xml` live in the separate [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) repo (`git@github.com:qiudaomao/clipboardSyncRelease.git`), not in this repo.

The current Windows release target is `v0.1.29`, matching the app version `0.1.29`.

## Publishing from macOS

The whole release can be cut from macOS; no Windows machine is needed. Differences from the
Windows flow below:

1. **Build**: use the official x64 .NET SDK in `~/.dotnet` with Windows targeting enabled.
   Publish **both** the app and the secure-desktop input service (the installer packages the
   service from its own publish output):

   ```sh
   ~/.dotnet/dotnet publish win/ClipboardSyncWin/ClipboardSyncWin.csproj \
     -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true
   ~/.dotnet/dotnet publish win/ClipboardSyncInputService/ClipboardSyncInputService.csproj \
     -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true
   ```

   (`build-windows.ps1` on Windows publishes both projects automatically; the macOS flow uses
   these raw commands, so the service publish must be run explicitly.)

2. **Installer**: run the Inno Setup compiler in Docker instead of installing it:

   ```sh
   docker run --rm --platform linux/amd64 \
     -e CLIPBOARD_SYNC_VERSION=<version> -e CLIPBOARD_SYNC_RELEASE_VERSION=v<version> \
     -v "$PWD:/work" -w /work/win/installer amake/innosetup ClipboardSyncWin.iss
   ```

   The installer lands in `artifacts/windows/` exactly like the PowerShell script's output.

3. **Ed25519 keys**: copy `NetSparkle_Ed25519.priv`/`.pub` from the Windows key machine
   (`%LOCALAPPDATA%\netsparkle\`) into `~/Library/Application Support/netsparkle/` once.
   Verify `--export` prints the public key compiled into `WinUpdateController.cs` before
   signing anything.

4. **Appcast generator quirks on macOS** (tool version 2.9.0):
   - The global-tool shim can be built for the wrong architecture; invoke the tool DLL
     directly: `~/.dotnet/dotnet exec --fx-version <installed 8.0.x> \
     ~/.dotnet/tools/.store/netsparkleupdater.tools.appcastgenerator/**/NetSparkleUpdater.Tools.AppCastGenerator.dll ...`
   - .NET cannot read a PE file's product version off-Windows, so the generator skips the
     installer unless you pass **`--file-extract-version`** (derives `0.1.20` from
     `...-v0.1.20.exe`).
   - Run the generator against a scratch directory (its output file is named `appcast.xml`,
     which would collide with the macOS appcast in the release checkout); copy the existing
     `win-appcast.xml` in as `appcast.xml` first so `--reparse-existing` keeps old items.
   - The standalone `--generate-signature` subcommand crashes on macOS. Use the
     `appcast.xml.signature` the generator writes next to the appcast during generation —
     the file is already LF on macOS, so that signature covers the exact bytes GitHub raw
     serves. Always verify before pushing: download the pushed raw `win-appcast.xml` and
     check the signature against the compiled public key.

## 1. One-time NetSparkle setup

Install the appcast generator and create one Ed25519 keypair:

```powershell
dotnet tool install --global NetSparkleUpdater.Tools.AppCastGenerator
netsparkle-generate-appcast --generate-keys
netsparkle-generate-appcast --export
```

Paste the exported public key into `PublicKey` in `win/ClipboardSyncWin/WinUpdateController.cs`.

Keep the private key outside the repo. Every update installer must be signed with the same private key, or installed apps will reject the update.

## 2. Bump the version

Edit both `win/ClipboardSyncWin/ClipboardSyncWin.csproj` and
`win/ClipboardSyncInputService/ClipboardSyncInputService.csproj`:

- `Version`
- `AssemblyVersion`
- `FileVersion`
- `InformationalVersion`

Use numeric .NET versions in the project file, for example `0.1.10`. Use the `v` prefix only for Git tags, GitHub release names, and installer filenames, for example `v0.1.10`.

Commit the version bump before building and publishing artifacts:

```powershell
git add win/ClipboardSyncWin/ClipboardSyncWin.csproj win/ClipboardSyncInputService/ClipboardSyncInputService.csproj release_windows.md
git commit -m "Bump Windows version to v0.1.10"
```

## 3. Build the installer

Install Inno Setup 6, then run:

```powershell
.\build-windows-installer.ps1 -Version 0.1.10 -ReleaseVersion v0.1.10 -StopRunning
```

If `-ReleaseVersion` is omitted, the script uses `v<Version>`.

By default the Windows installer is framework-dependent and requires users to have the .NET 8 Desktop Runtime (x64). If it is missing, the .NET app host shows Microsoft's runtime install guidance when the app launches.

To build the older larger self-contained package instead, pass `-SelfContained`.

The installer is written to:

```text
artifacts/windows/ClipboardSyncSetup-v0.1.10.exe
```

## 4. Upload the installer

Create a GitHub Release in `clipboardSyncRelease` and attach the installer:

```powershell
gh release create v0.1.10 artifacts/windows/ClipboardSyncSetup-v0.1.10.exe `
  --repo qiudaomao/clipboardSyncRelease `
  --title "v0.1.10" `
  --notes "release notes here"
```

This gives the public download URL:

```text
https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v0.1.10/ClipboardSyncSetup-v0.1.10.exe
```

## 5. Generate and publish the appcast

In a local checkout of `clipboardSyncRelease`, place the installer in a temporary folder and generate or update `win-appcast.xml`:

```powershell
netsparkle-generate-appcast `
  -a . `
  -b path\to\folder-with-installer `
  -e exe `
  -o windows-x64 `
  -n "Clipboard Sync" `
  -u "https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v0.1.10" `
  --reparse-existing `
  --overwrite-old-items
```

Rename the generated appcast to `win-appcast.xml` if needed, then normalize it to LF line endings before generating the appcast signature. The release repo serves appcasts from GitHub raw with LF bytes, so the signature must be generated from the same bytes users will download:

```powershell
$path = "win-appcast.xml"
$text = [System.IO.File]::ReadAllText($path) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
```

Generate the appcast signature:

```powershell
netsparkle-generate-appcast --generate-signature win-appcast.xml
```

Save the printed signature as `win-appcast.xml.signature` beside `win-appcast.xml`.

Commit and push `win-appcast.xml` and `win-appcast.xml.signature` to `main` in `clipboardSyncRelease`. Since the Windows app points at `raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/win-appcast.xml`, pushing those files makes the update live.

## Mirror note

The app falls back to `win-appcast-mirror.xml` served via jsDelivr when GitHub is unreachable
(see `WinUpdateController.cs`). After publishing, update the newest `<item>` in
`win-appcast-mirror.xml` in `clipboardSyncRelease` to match `win-appcast.xml`, with the
enclosure URL routed through the GitHub download proxy (jsDelivr refuses `.exe` files):

```
https://gh-proxy.com/https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v<version>/ClipboardSyncSetup-v<version>.exe
```

Then purge the feed cache:

```powershell
curl.exe -s "https://purge.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/win-appcast-mirror.xml"
```

The proxy host can be swapped in that file at any time without an app update; the Ed25519
signature check protects the download no matter which host serves it.
