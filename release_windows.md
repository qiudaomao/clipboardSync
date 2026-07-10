# Releasing a Windows Update

Steps to cut a Windows release and publish it through NetSparkle auto-update.

Release artifacts and `win-appcast.xml` live in the separate [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) repo (`git@github.com:qiudaomao/clipboardSyncRelease.git`), not in this repo.

The current Windows release target is `v0.1.17`, matching the app version `0.1.17`.

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

Edit `win/ClipboardSyncWin/ClipboardSyncWin.csproj`:

- `Version`
- `AssemblyVersion`
- `FileVersion`
- `InformationalVersion`

Use numeric .NET versions in the project file, for example `0.1.10`. Use the `v` prefix only for Git tags, GitHub release names, and installer filenames, for example `v0.1.10`.

Commit the version bump before building and publishing artifacts:

```powershell
git add win/ClipboardSyncWin/ClipboardSyncWin.csproj release_windows.md
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
