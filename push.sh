#!/usr/bin/env bash
# Fetch the latest macOS/Windows build from qiudaomao/clipboardSyncRelease,
# publish them under fixed filenames to the download server (so the landing
# page's download links never need to change when the release tag bumps),
# and push the landing page itself (index.html + assets).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="qiudaomao/clipboardSyncRelease"
SITE_REMOTE="hk:/usr/share/nginx/html/static/clipboardSync"
DOWNLOADS_REMOTE="$SITE_REMOTE/downloads"
PUBLIC_BASE="https://clipboardsync.fuzhuo.me/downloads"

command -v gh >/dev/null 2>&1 || { echo "!! gh CLI is required (brew install gh && gh auth login)" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Fetching latest release info for $REPO"
RELEASE_JSON="$(gh release view --repo "$REPO" --json tagName,assets)"

TAG="$(jq -r '.tagName' <<<"$RELEASE_JSON")"
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "!! Could not resolve latest release tag" >&2
  exit 1
fi
echo "==> Latest tag: $TAG"

MAC_NAME="$(jq -r '.assets[] | select(.name | test("Mac.*\\.zip$")) | .name' <<<"$RELEASE_JSON" | head -1)"
WIN_NAME="$(jq -r '.assets[] | select(.name | test("Win.*\\.exe$")) | .name' <<<"$RELEASE_JSON" | head -1)"

if [ -z "$MAC_NAME" ]; then
  echo "!! No macOS .zip asset found in release $TAG" >&2
  exit 1
fi
if [ -z "$WIN_NAME" ]; then
  echo "!! No Windows .exe asset found in release $TAG" >&2
  exit 1
fi

echo "==> macOS asset:   $MAC_NAME"
echo "==> Windows asset: $WIN_NAME"

echo "==> Downloading via gh..."
gh release download "$TAG" --repo "$REPO" -p "$MAC_NAME" -p "$WIN_NAME" -D "$WORKDIR" --clobber
mv "$WORKDIR/$MAC_NAME" "$WORKDIR/clipboardSyncMac.zip"
mv "$WORKDIR/$WIN_NAME" "$WORKDIR/clipboardSyncWin-Setup.exe"

echo "==> Uploading builds to $DOWNLOADS_REMOTE"
scp "$WORKDIR/clipboardSyncMac.zip" "$WORKDIR/clipboardSyncWin-Setup.exe" "$DOWNLOADS_REMOTE/"

echo "==> Uploading landing page to $SITE_REMOTE"
scp "$SCRIPT_DIR/index.html" "$SITE_REMOTE/"
scp -r "$SCRIPT_DIR/assets" "$SITE_REMOTE/"

echo "==> Done. Published $TAG:"
echo "    https://clipboardsync.fuzhuo.me/"
echo "    $PUBLIC_BASE/clipboardSyncMac.zip"
echo "    $PUBLIC_BASE/clipboardSyncWin-Setup.exe"
