# Releasing a macOS Update

> Prefer **[release_all.md](release_all.md)** when shipping macOS + Windows + Linux together.
> This file is the macOS-only deep dive (Sparkle, notarization, appcast format).

Steps to cut a new macOS release, notarize it, and publish it through Sparkle 2 auto-update.

Releases are published from **this repo**: the zipped app is uploaded as a GitHub release asset here, and the update feeds live in [`assets/`](../assets) (`appcast.xml`, `appcast-mirror.xml`). The app's `SUFeedURL` in `mac/App/Info.plist` points at `https://raw.githubusercontent.com/qiudaomao/clipboardSync/main/assets/appcast.xml`.

> **Migration note:** installs of v0.2.1 and earlier still poll the old
> [clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease) feeds, so the
> **next two releases must also be prepended** to the old repo's `appcast.xml` /
> `appcast-mirror.xml` (their enclosure URLs may point at this repo's release assets) —
> otherwise old clients cannot see the update. Keep the old repo online afterwards; it serves
> the old download URLs and remains the jsDelivr mirror bucket.

The EdDSA private signing key (Sparkle) lives in the login Keychain on the machine that ran `generate_keys` (see [Build.md](Build.md)). Every release must be signed with that same key or existing installs will reject the update.

Notarization needs a `notarytool` credential profile stored once via `xcrun notarytool store-credentials "AC_NOTARY" --apple-id ... --team-id SGZE33W2XX --password <app-specific password>`. Check it's present with `xcrun notarytool history --keychain-profile AC_NOTARY`.

**Do not use `xcodebuild build` for releases.** It injects a `get-task-allow` debug entitlement and skips secure timestamps — either one causes notarization to fail. Always use `archive` + `-exportArchive`.

## 1. Bump the version

Edit `mac/ClipboardSyncMac.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION` — user-facing version, e.g. `0.2.0`.
- `CURRENT_PROJECT_VERSION` — build number, must strictly increase across releases, e.g. `3`.

Both the Debug and Release `XCBuildConfiguration` blocks carry these keys; update both.

Also refresh the beta license window in `mac/Sources/ClipboardSyncMac/BetaLicense.swift`:
set `releaseDate` to today (UTC). If it is left stale, the build expires `durationDays`
after the *old* date and users see “beta expired” even after updating.

## 2. Archive and export a Developer ID build

```sh
rm -rf mac/DerivedData/Archive.xcarchive mac/DerivedData/Export

xcodebuild -project mac/ClipboardSyncMac.xcodeproj -scheme ClipboardSyncMac \
  -configuration Release -archivePath mac/DerivedData/Archive.xcarchive archive

xcodebuild -exportArchive \
  -archivePath mac/DerivedData/Archive.xcarchive \
  -exportPath mac/DerivedData/Export \
  -exportOptionsPlist mac/ExportOptions.plist
```

`mac/ExportOptions.plist` is checked in with `method: developer-id`, `teamID: SGZE33W2XX`, `signingCertificate: Developer ID Application`. This is what deep-signs the nested Sparkle helper binaries (Autoupdate, XPC services, Updater.app) with a secure timestamp — `xcodebuild build` does not do this correctly for SPM-embedded frameworks.

Sanity check before continuing:

```sh
codesign -dvv mac/DerivedData/Export/ClipboardSync.app 2>&1 | grep -E "Authority|Timestamp"
```

Should show `Authority=Developer ID Application: ...` and a `Timestamp=` line.

## 3. Zip, notarize, staple

```sh
cd mac/DerivedData/Export
ditto -c -k --sequesterRsrc --keepParent ClipboardSync.app ClipboardSync-<version>.zip

xcrun notarytool submit ClipboardSync-<version>.zip --keychain-profile "AC_NOTARY" --wait
```

Wait for `status: Accepted`. If it comes back `Invalid`, pull the log to see why:

```sh
xcrun notarytool log <submission-id> --keychain-profile "AC_NOTARY"
```

Once accepted, staple the ticket to the `.app` (not the zip) and re-zip, since stapling changes the app's contents:

```sh
xcrun stapler staple ClipboardSync.app
rm ClipboardSync-<version>.zip
ditto -c -k --sequesterRsrc --keepParent ClipboardSync.app ClipboardSync-<version>.zip
```

Verify Gatekeeper accepts it the way a downloader's Mac would (simulating the quarantine flag a browser download adds):

```sh
spctl -a -vv ClipboardSync.app
```

Should print `accepted` / `source=Notarized Developer ID`.

## 4. Sign the zip for Sparkle

```sh
mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update mac/DerivedData/Export/ClipboardSync-<version>.zip
```

Note the printed `sparkle:edSignature` and file `length` — both go into the appcast entry. Sign the zip *after* stapling — stapling changes the file, so any signature taken before it won't match.

## 5. Upload the zip to a GitHub release on this repo

```sh
gh release create v<version> mac/DerivedData/Export/ClipboardSync-<version>.zip \
  --repo qiudaomao/clipboardSync \
  --title "v<version>" \
  --notes "release notes here"
```

This gives the public download URL:

```
https://github.com/qiudaomao/clipboardSync/releases/download/v<version>/ClipboardSync-<version>.zip
```

## 6. Add the appcast entry and publish

Add a new `<item>` to [`assets/appcast.xml`](../assets/appcast.xml), newest first:

```xml
<item>
    <title><version></title>
    <pubDate>Thu, 02 Jul 2026 00:00:00 +0000</pubDate>
    <sparkle:version><CURRENT_PROJECT_VERSION></sparkle:version>
    <sparkle:shortVersionString><version></sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/qiudaomao/clipboardSync/releases/download/v<version>/ClipboardSync-<version>.zip"
        sparkle:edSignature="<signature from sign_update>"
        length="<file length from sign_update>"
        type="application/octet-stream" />
</item>
```

Commit and push `assets/appcast.xml` to `main`. Since `SUFeedURL` points at `raw.githubusercontent.com/qiudaomao/clipboardSync/main/assets/appcast.xml`, pushing to `main` is what makes the update live for everyone currently running the app — do this last, once the release asset is uploaded, notarized, stapled, and the signature is verified.

While older installs still poll the old feed, prepend the same `<item>` to `appcast.xml` in the `clipboardSyncRelease` repo too (see the migration note at the top).

## 7. Refresh the jsDelivr mirror

The app falls back to a jsDelivr-served mirror feed when GitHub is unreachable (see
`UpdateController.swift`):

Release binaries stay out of this repo's git history (`releases/` is gitignored), so the
jsDelivr-served zips live in the old `clipboardSyncRelease` repo, which stays online as the
mirror bucket:

1. Commit the final zip into `releases/` in a checkout of `clipboardSyncRelease` and push
   (jsDelivr serves repo files up to 20 MB; zips are fine, `.exe` is refused — Windows uses a
   download proxy instead, see `assets/win-appcast-mirror.xml`).
2. Prepend the new `<item>` to `assets/appcast-mirror.xml` in this repo: same fields and
   signature as `appcast.xml`, but the enclosure URL is
   `https://cdn.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/releases/ClipboardSync-<version>.zip`.
3. Commit and push together with `assets/appcast.xml`, then purge the CDN caches so the mirror
   updates immediately instead of after ~12h:

```sh
curl -s "https://purge.jsdelivr.net/gh/qiudaomao/clipboardSync@main/assets/appcast-mirror.xml"
curl -s "https://purge.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/releases/ClipboardSync-<version>.zip"
```

Old zips in the release repo's `releases/` can be deleted once a newer release is mirrored; the
mirror only needs the entries the mirror appcast still references.

## 8. Publish the self-hosted mirror

Run `./script/push.sh`. By default the **mirror host pulls large assets from GitHub** (or
`GH_PROXY`), skips files that already match size+sha256, rewrites appcast enclosures to
`https://clipboardsync.fuzhuo.me/downloads/`, scp’s only the small appcasts + landing page,
then verifies with remote `sha256sum` and a public HTTP HEAD — no full re-download.

- `./script/push.sh --retry` — skip assets already correct on the server.
- `./script/push.sh --verify-only` — hash + HEAD only.
- `./script/push.sh --scp` — force laptop download + scp (fallback).
- See [release_all.md](release_all.md) §5 for the full efficiency notes.
