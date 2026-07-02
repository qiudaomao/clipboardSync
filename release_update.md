# Releasing a macOS Update

Steps to cut a new macOS release and publish it through Sparkle 2 auto-update.

Release artifacts (the zipped app and `appcast.xml`) live in the separate [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) repo (`git@github.com:qiudaomao/clipboardSyncRelease.git`), not in this repo. The app's `SUFeedURL` in `mac/App/Info.plist` points at `appcast.xml` there.

The EdDSA private signing key lives in the login Keychain on the machine that ran `generate_keys` (see [Build.md](Build.md)). Every release must be signed with that same key or existing installs will reject the update.

## 1. Bump the version

Edit `mac/ClipboardSyncMac.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION` — user-facing version, e.g. `0.2.0`.
- `CURRENT_PROJECT_VERSION` — build number, must strictly increase across releases, e.g. `2`.

Both the Debug and Release `XCBuildConfiguration` blocks carry these keys; update both.

## 2. Build Release and zip the app

```sh
xcodebuild \
  -project mac/ClipboardSyncMac.xcodeproj \
  -scheme ClipboardSyncMac \
  -configuration Release \
  -derivedDataPath mac/DerivedData \
  build

cd mac/DerivedData/Build/Products/Release
ditto -c -k --sequesterRsrc --keepParent ClipboardSyncMac.app ClipboardSyncMac-<version>.zip
```

Use `ditto`, not `zip` — it preserves the app bundle structure and resource forks the way Sparkle expects.

## 3. Sign the zip

```sh
mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update ClipboardSyncMac-<version>.zip
```

Note the printed `sparkle:edSignature` and file `length` — both go into the appcast entry.

If that path doesn't exist (fresh checkout, package not yet resolved), build once first so Xcode resolves the Sparkle package and places its `bin/` tools under `mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`.

## 4. Upload the zip to a release in clipboardSyncRelease

Clone `clipboardSyncRelease` next to this repo if you don't already have it checked out, then create the GitHub Release there (not in `clipboardSync`) and attach the zip:

```sh
gh release create v<version> ClipboardSyncMac-<version>.zip \
  --repo qiudaomao/clipboardSyncRelease \
  --title "v<version>" \
  --notes "release notes here"
```

This gives the public download URL:

```
https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v<version>/ClipboardSyncMac-<version>.zip
```

## 5. Add the appcast entry and publish

In your local checkout of `clipboardSyncRelease`, add a new `<item>` to `appcast.xml`, newest first:

```xml
<item>
    <title><version></title>
    <pubDate>Thu, 02 Jul 2026 00:00:00 +0000</pubDate>
    <sparkle:version><CURRENT_PROJECT_VERSION></sparkle:version>
    <sparkle:shortVersionString><version></sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v<version>/ClipboardSyncMac-<version>.zip"
        sparkle:edSignature="<signature from sign_update>"
        length="<file length from sign_update>"
        type="application/octet-stream" />
</item>
```

Commit and push `appcast.xml` to `main` in `clipboardSyncRelease`. Since `SUFeedURL` points at `raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/appcast.xml`, pushing to `main` there is what makes the update live for everyone currently running the app — do this last, once the release asset is uploaded and the signature is verified.
