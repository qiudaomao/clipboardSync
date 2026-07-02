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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Fetching latest release info for $REPO"
RELEASE_JSON="$(curl -sfL -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/latest")"

TAG="$(jq -r '.tag_name' <<<"$RELEASE_JSON")"
if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "!! Could not resolve latest release tag (GitHub API rate limited?)" >&2
  exit 1
fi
echo "==> Latest tag: $TAG"

MAC_URL="$(jq -r '.assets[] | select(.name | test("Mac.*\\.zip$")) | .browser_download_url' <<<"$RELEASE_JSON" | head -1)"
WIN_URL="$(jq -r '.assets[] | select(.name | test("Win.*\\.exe$")) | .browser_download_url' <<<"$RELEASE_JSON" | head -1)"

if [ -z "$MAC_URL" ]; then
  echo "!! No macOS .zip asset found in release $TAG" >&2
  exit 1
fi
if [ -z "$WIN_URL" ]; then
  echo "!! No Windows .exe asset found in release $TAG" >&2
  exit 1
fi

echo "==> macOS asset:   $MAC_URL"
echo "==> Windows asset: $WIN_URL"

echo "==> Downloading..."
curl -fL --progress-bar "$MAC_URL" -o "$WORKDIR/clipboardSyncMac.zip"
curl -fL --progress-bar "$WIN_URL" -o "$WORKDIR/clipboardSyncWin-Setup.exe"

echo "==> Uploading builds to $DOWNLOADS_REMOTE"
scp "$WORKDIR/clipboardSyncMac.zip" "$WORKDIR/clipboardSyncWin-Setup.exe" "$DOWNLOADS_REMOTE/"

echo "==> Uploading landing page to $SITE_REMOTE"
scp "$SCRIPT_DIR/index.html" "$SITE_REMOTE/"
scp -r "$SCRIPT_DIR/assets" "$SITE_REMOTE/"

echo "==> Done. Published $TAG:"
echo "    https://clipboardsync.fuzhuo.me/"
echo "    $PUBLIC_BASE/clipboardSyncMac.zip"
echo "    $PUBLIC_BASE/clipboardSyncWin-Setup.exe"
