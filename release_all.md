# Releasing All Platforms (macOS + Windows + Linux)

End-to-end checklist for cutting a single cross-platform release from a Mac.
Platform-specific deep dives still live in:

- [release_update.md](release_update.md) — macOS Sparkle / notarization details
- [release_windows.md](release_windows.md) — Windows NetSparkle / Inno Setup details
- [linux/README.md](linux/README.md) — Flatpak / update details

Artifacts and appcasts are published to
[clipboardSyncRelease](https://github.com/qiudaomao/clipboardSyncRelease)
(`git@github.com:qiudaomao/clipboardSyncRelease.git`), not this repo. The
self-hosted mirror at `https://clipboardsync.fuzhuo.me` is refreshed with
[`./push.sh`](push.sh).

Set these once per release:

```sh
VERSION=0.1.30          # numeric, no v
TAG=v${VERSION}
NOTES="One-line user-facing summary of what changed."
RELEASE_REPO="$HOME/proj/github/clipboardSyncRelease"   # local checkout
```

---

## 0. Prerequisites (once per machine)

| Need | Check |
|------|--------|
| Developer ID Application cert | `security find-identity -v -p codesigning` |
| Notary credentials | `xcrun notarytool history --keychain-profile AC_NOTARY` **or** pass `--apple-id` / `--team-id` / `--password` on each submit |
| Sparkle `sign_update` | `mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` (resolve packages once via Xcode/archive) |
| .NET 8 SDK + Windows targeting | `~/.dotnet/dotnet --list-sdks` |
| NetSparkle Ed25519 keys | `~/Library/Application Support/netsparkle/NetSparkle_Ed25519.{priv,pub}` matching `WinUpdateController.cs` |
| NetSparkle appcast generator | `~/.dotnet/tools/.store/netsparkleupdater.tools.appcastgenerator/**/NetSparkleUpdater.Tools.AppCastGenerator.dll` |
| Docker (Inno Setup + Flatpak) | `docker info` (OrbStack/Colima fine) |
| `gh` auth with write on release repo | `gh auth status` |
| SSH host `hk` for the self-hosted mirror | `ssh hk 'echo ok'` |

---

## 1. Bump the version (all platforms)

Update every platform in one commit so the shared release tag is consistent.

| Platform | Files | Fields |
|----------|--------|--------|
| macOS | `mac/ClipboardSyncMac.xcodeproj/project.pbxproj` | `MARKETING_VERSION` (both Debug/Release) and `CURRENT_PROJECT_VERSION` (must **strictly increase**, e.g. `29` → `30`) |
| Windows | `win/ClipboardSyncWin/ClipboardSyncWin.csproj`, `win/ClipboardSyncInputService/ClipboardSyncInputService.csproj` | `Version`, `AssemblyVersion`, `FileVersion`, `InformationalVersion` |
| Linux | `linux/CMakeLists.txt` | `project(... VERSION x.y.z ...)` |
| Linux | `linux/packaging/io.github.qiudaomao.clipboardsync.metainfo.xml` | prepend `<release version="x.y.z" date="YYYY-MM-DD"/>` |
| Docs | `release_windows.md` | “current Windows release target” line |

```sh
git add mac/ClipboardSyncMac.xcodeproj/project.pbxproj \
  win/ClipboardSyncWin/ClipboardSyncWin.csproj \
  win/ClipboardSyncInputService/ClipboardSyncInputService.csproj \
  linux/CMakeLists.txt \
  linux/packaging/io.github.qiudaomao.clipboardsync.metainfo.xml \
  release_windows.md
git commit -m "Bump version to ${TAG}"
```

Push the version bump **before or right after** the GitHub release; do not leave it local-only.

---

## 2. Build all three platforms (parallel)

Run macOS, Windows, and Linux builds in parallel terminals. Outputs:

| Platform | Output |
|----------|--------|
| macOS | `mac/DerivedData/Export-v${VERSION}/ClipboardSync-${VERSION}.zip` |
| Windows | `artifacts/windows/ClipboardSyncSetup-${TAG}.exe` |
| Linux | `artifacts/linux/clipboardSyncLinux-{x86_64,aarch64}.flatpak` |

### 2a. macOS (archive → export → notarize → staple → Sparkle sign)

**Always `archive` + `-exportArchive`.** Plain `xcodebuild build` injects `get-task-allow` and skips secure timestamps; notarization will fail.

```sh
rm -rf "mac/DerivedData/Archive-v${VERSION}.xcarchive" "mac/DerivedData/Export-v${VERSION}"

xcodebuild -project mac/ClipboardSyncMac.xcodeproj -scheme ClipboardSyncMac \
  -configuration Release \
  -derivedDataPath mac/DerivedData \
  -archivePath "mac/DerivedData/Archive-v${VERSION}.xcarchive" \
  archive

# Export can flake on Apple's timestamp server — retry a few times if you see
# "A timestamp was expected but was not found."
xcodebuild -exportArchive \
  -archivePath "mac/DerivedData/Archive-v${VERSION}.xcarchive" \
  -exportPath "mac/DerivedData/Export-v${VERSION}" \
  -exportOptionsPlist mac/ExportOptions.plist

codesign -dvv "mac/DerivedData/Export-v${VERSION}/ClipboardSync.app" 2>&1 \
  | grep -E "Authority|Timestamp"
# Expect: Developer ID Application + a Timestamp= line

cd "mac/DerivedData/Export-v${VERSION}"
ditto -c -k --sequesterRsrc --keepParent ClipboardSync.app \
  "ClipboardSync-${VERSION}-notarization.zip"

# Prefer keychain profile when available; otherwise pass credentials directly:
xcrun notarytool submit "ClipboardSync-${VERSION}-notarization.zip" \
  --keychain-profile AC_NOTARY --wait
# OR:
# xcrun notarytool submit "ClipboardSync-${VERSION}-notarization.zip" \
#   --apple-id "…" --team-id SGZE33W2XX --password "…" --wait

xcrun stapler staple ClipboardSync.app
ditto -c -k --sequesterRsrc --keepParent ClipboardSync.app \
  "ClipboardSync-${VERSION}.zip"
spctl -a -vv ClipboardSync.app   # accepted / Notarized Developer ID

# Sign from repo root so the relative path is unambiguous:
cd "$OLDPWD"
mac/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  "mac/DerivedData/Export-v${VERSION}/ClipboardSync-${VERSION}.zip"
# Save sparkle:edSignature and length= for the appcast item.
```

### 2b. Windows (from macOS)

```sh
~/.dotnet/dotnet publish win/ClipboardSyncWin/ClipboardSyncWin.csproj \
  -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true
~/.dotnet/dotnet publish win/ClipboardSyncInputService/ClipboardSyncInputService.csproj \
  -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true

docker run --rm --platform linux/amd64 \
  -e CLIPBOARD_SYNC_VERSION="${VERSION}" \
  -e CLIPBOARD_SYNC_RELEASE_VERSION="${TAG}" \
  -v "$PWD:/work" -w /work/win/installer \
  amake/innosetup ClipboardSyncWin.iss

ls -la "artifacts/windows/ClipboardSyncSetup-${TAG}.exe"
```

### 2c. Linux Flatpaks (both arches, local Docker)

```sh
./build-linux-flatpak.sh aarch64 x86_64
ls -la artifacts/linux/clipboardSyncLinux-*.flatpak
```

`x86_64` under QEMU is slower but works. CI (`.github/workflows/linux-release.yml`)
can also build x86_64 on tag push; aarch64 still needs a native ARM host or this script.

---

## 3. Upload assets to clipboardSyncRelease

Create one GitHub release that carries **all four** assets:

```sh
gh release create "${TAG}" \
  "mac/DerivedData/Export-v${VERSION}/ClipboardSync-${VERSION}.zip" \
  "artifacts/windows/ClipboardSyncSetup-${TAG}.exe" \
  artifacts/linux/clipboardSyncLinux-x86_64.flatpak \
  artifacts/linux/clipboardSyncLinux-aarch64.flatpak \
  --repo qiudaomao/clipboardSyncRelease \
  --title "${TAG}" \
  --notes "${NOTES}"
```

If the release already exists (e.g. Linux CI created an empty one):

```sh
gh release upload "${TAG}" \
  "mac/DerivedData/Export-v${VERSION}/ClipboardSync-${VERSION}.zip" \
  "artifacts/windows/ClipboardSyncSetup-${TAG}.exe" \
  artifacts/linux/clipboardSyncLinux-x86_64.flatpak \
  artifacts/linux/clipboardSyncLinux-aarch64.flatpak \
  --repo qiudaomao/clipboardSyncRelease --clobber
```

---

## 4. Update appcasts in clipboardSyncRelease

Work in the local `clipboardSyncRelease` checkout. Commit **after** the release
assets are uploaded so enclosure URLs resolve.

### 4a. macOS `appcast.xml` + `appcast-mirror.xml`

Prepend a new `<item>` (newest first). Use the `sign_update` signature/length and
`CURRENT_PROJECT_VERSION` as `sparkle:version`:

```xml
<item>
    <title>0.1.30</title>
    <description>…</description>
    <pubDate>… RFC 2822 UTC …</pubDate>
    <sparkle:version>30</sparkle:version>
    <sparkle:shortVersionString>0.1.30</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/qiudaomao/clipboardSyncRelease/releases/download/v0.1.30/ClipboardSync-0.1.30.zip"
        sparkle:edSignature="…"
        length="…"
        type="application/octet-stream" />
</item>
```

Mirror feed: same item, enclosure URL =

`https://cdn.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/releases/ClipboardSync-${VERSION}.zip`

Also copy the stapled zip into `releases/` for jsDelivr:

```sh
cp "…/ClipboardSync-${VERSION}.zip" "${RELEASE_REPO}/releases/"
```

### 4b. Windows `win-appcast.xml` + signature + mirror

Generate from macOS (tool 2.9.0 quirks — see [release_windows.md](release_windows.md)):

```sh
APPCAST_GEN=$(find ~/.dotnet/tools/.store/netsparkleupdater.tools.appcastgenerator \
  -name 'NetSparkleUpdater.Tools.AppCastGenerator.dll' | head -1)
FX=$(~/.dotnet/dotnet --list-runtimes | awk '/Microsoft.NETCore.App 8\./{print $2}' | tail -1)
WORKDIR=$(mktemp -d)
CHANGELOG_DIR="$WORKDIR/changelogs"
mkdir -p "$CHANGELOG_DIR"

cp "artifacts/windows/ClipboardSyncSetup-${TAG}.exe" "$WORKDIR/"
# Seed with existing feed (LF) so --reparse-existing keeps history:
python3 - <<PY
from pathlib import Path
src = Path("${RELEASE_REPO}/win-appcast.xml").read_text().replace("\r\n", "\n")
Path("${WORKDIR}/appcast.xml").write_bytes(src.encode())
PY
# Place the exact user-facing release note in "$CHANGELOG_DIR/${VERSION}.md" before
# generating. The generator puts it in the item's <description> before it signs the feed.

~/.dotnet/dotnet exec --fx-version "$FX" "$APPCAST_GEN" \
  -a "$WORKDIR" -b "$WORKDIR" -e exe -o windows-x64 \
  -n "Clipboard Sync" \
  -u "https://github.com/qiudaomao/clipboardSyncRelease/releases/download/${TAG}" \
  -p "$CHANGELOG_DIR" \
  --reparse-existing --overwrite-old-items --file-extract-version

# Use the signature file written *with* the appcast (already LF on macOS):
cp "$WORKDIR/appcast.xml" "${RELEASE_REPO}/win-appcast.xml"
cp "$WORKDIR/appcast.xml.signature" "${RELEASE_REPO}/win-appcast.xml.signature"
```

Update `win-appcast-mirror.xml`: same newest item as `win-appcast.xml`, but enclosure URL through the GitHub download proxy (jsDelivr refuses `.exe`):

```
https://gh-proxy.com/https://github.com/qiudaomao/clipboardSyncRelease/releases/download/${TAG}/ClipboardSyncSetup-${TAG}.exe
```

### 4c. Commit, push, purge jsDelivr

```sh
cd "${RELEASE_REPO}"
git add appcast.xml appcast-mirror.xml \
  win-appcast.xml win-appcast.xml.signature win-appcast-mirror.xml \
  "releases/ClipboardSync-${VERSION}.zip"
git commit -m "Publish macOS, Windows, and Linux ${TAG}"
git push origin main

curl -s "https://purge.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/appcast-mirror.xml"
curl -s "https://purge.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/win-appcast-mirror.xml"
```

Confirm raw feeds show the new version:

```sh
curl -sL https://raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/appcast.xml | head -25
curl -sL https://raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/win-appcast.xml | head -15
```

---

## 5. Self-hosted mirror (`./push.sh`)

Default path is **server-side fetch**, not laptop download → scp:

1. On `hk`, `curl`/`wget` each large release asset from GitHub (optional `GH_PROXY=…`).
2. Skip any remote file that already matches GitHub **size + sha256 digest**.
3. Create fixed-name aliases on the server (`clipboardSyncMac.zip`, …) with `cp`.
4. Locally rewrite appcasts (enclosures → `https://clipboardsync.fuzhuo.me/downloads/`) and **scp only those small files + the landing page**.
5. Verify with **`sha256sum` over SSH** (no body re-download) plus a cheap public HTTP **HEAD** (Content-Length only).

```sh
./push.sh                              # remote-fetch assets, scp appcasts/site, verify
./push.sh --retry                      # skip assets already correct on the server
./push.sh --verify-only                # hash + HEAD only
./push.sh --scp                        # force old local-download + scp path
GH_PROXY=https://gh-proxy.com/ ./push.sh   # if the host reaches GitHub slowly
```

### Why this is better

| Approach | Cost | Integrity |
|----------|------|-----------|
| laptop download + scp + HTTP GET verify | 2× transfer of multi‑MB files through your Mac | weak (size only if HEAD) |
| **server curl + remote sha256 + HEAD** (default) | 1× transfer host↔GitHub; laptop only moves ~KB appcasts | strong (GitHub digest vs `sha256sum` on disk) |

- Public verify uses **HEAD**, not a full download — it only checks that nginx answers 200 with the right `Content-Length`.
- After scp of appcasts, remote sha256 is compared to the local rewritten bytes.
- If remote GitHub fetch fails mid-run, the script falls back to `--scp` for the remaining assets.
- `LINUX_BUNDLE=/path` still scp’s that one local file (it is not on GitHub).

---

## 6. Source repo push

```sh
git push origin main
```

Optional: tag this repo for the Linux CI workflow (`on: push: tags: ["v*"]`). The
local Flatpak build in §2c already covers both arches, so the tag is optional
when you upload flatpaks yourself.

---

## 7. Final checklist

- [ ] Version fields bumped on mac / win / linux; commit pushed
- [ ] macOS zip notarized, stapled, Sparkle-signed
- [ ] Windows installer built; NetSparkle enclosure signature present
- [ ] Linux x86_64 + aarch64 flatpaks present
- [ ] GitHub release `${TAG}` has all four assets
- [ ] `appcast.xml` / `win-appcast.xml` (+ mirrors + signature) on release repo `main`
- [ ] jsDelivr purged
- [ ] `./push.sh` succeeded (or `./push.sh --retry` after a flake)
- [ ] Spot-check: https://clipboardsync.fuzhuo.me/ and a sample download URL

---

## Quick command map

| Step | Command / location |
|------|--------------------|
| Bump | pbxproj + 2× csproj + CMake + metainfo |
| Mac build | `xcodebuild archive` → `exportArchive` → `notarytool` → `stapler` → `sign_update` |
| Win build | `dotnet publish` ×2 → `docker … amake/innosetup` |
| Linux build | `./build-linux-flatpak.sh aarch64 x86_64` |
| Release assets | `gh release create/upload … --repo qiudaomao/clipboardSyncRelease` |
| Appcasts | edit + NetSparkle generator in release checkout |
| Mirror | `./push.sh` then `./push.sh --retry` if needed |
