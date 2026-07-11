#!/usr/bin/env bash
# Publish the self-hosted update mirror and landing page at clipboardsync.fuzhuo.me:
#  - the latest macOS .zip, Windows .exe, and Linux .flatpak bundles (one per architecture,
#    produced by .github/workflows/linux-release.yml) from qiudaomao/clipboardSyncRelease,
#    under both their versioned names (referenced by the mirrored appcasts) and fixed names
#    (referenced by the landing page's download links); an x86_64 Linux bundle can also be
#    supplied locally via LINUX_BUNDLE=/path/to.flatpak (e.g. built with
#    `flatpak build-bundle <repo> out.flatpak io.github.qiudaomao.clipboardsync master`),
#  - appcast.xml / win-appcast.xml rewritten so enclosure URLs point at this server, giving
#    the apps a GitHub-independent update source (see UpdateController / WinUpdateController),
#  - the landing page itself (index.html + assets).
# Every published resource is verified over its public URL afterwards; the script fails if
# anything is missing or truncated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="qiudaomao/clipboardSyncRelease"
SITE_REMOTE="hk:/usr/share/nginx/html/static/clipboardSync"
DOWNLOADS_REMOTE="$SITE_REMOTE/downloads"
PUBLIC_SITE="https://clipboardsync.fuzhuo.me"
PUBLIC_BASE="$PUBLIC_SITE/downloads"

command -v gh >/dev/null 2>&1 || { echo "!! gh CLI is required (brew install gh && gh auth login)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "!! jq is required (brew install jq)" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# macOS and Windows releases are cut independently and live under different tags, so find the
# newest release that carries each platform's asset instead of assuming one release has both.
echo "==> Locating latest platform assets in $REPO"
MAC_TAG="" MAC_NAME="" WIN_TAG="" WIN_NAME="" LINUX_TAG="" LINUX_NAMES=""
while IFS=$'\t' read -r tag; do
  assets="$(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name')"
  if [ -z "$MAC_NAME" ]; then
    candidate="$(grep -E '\.zip$' <<<"$assets" | head -1 || true)"
    if [ -n "$candidate" ]; then MAC_TAG="$tag"; MAC_NAME="$candidate"; fi
  fi
  if [ -z "$WIN_NAME" ]; then
    candidate="$(grep -E '\.exe$' <<<"$assets" | head -1 || true)"
    if [ -n "$candidate" ]; then WIN_TAG="$tag"; WIN_NAME="$candidate"; fi
  fi
  if [ -z "$LINUX_NAMES" ]; then
    candidates="$(grep -E '\.flatpak$' <<<"$assets" || true)"
    if [ -n "$candidates" ]; then LINUX_TAG="$tag"; LINUX_NAMES="$candidates"; fi
  fi
  [ -n "$MAC_NAME" ] && [ -n "$WIN_NAME" ] && [ -n "$LINUX_NAMES" ] && break
done < <(gh release list --repo "$REPO" --limit 15 --json tagName --jq '.[].tagName')

[ -n "$MAC_NAME" ] || { echo "!! No macOS .zip asset found in recent releases" >&2; exit 1; }
[ -n "$WIN_NAME" ] || { echo "!! No Windows .exe asset found in recent releases" >&2; exit 1; }
echo "==> macOS asset:   $MAC_NAME ($MAC_TAG)"
echo "==> Windows asset: $WIN_NAME ($WIN_TAG)"
if [ -n "${LINUX_BUNDLE:-}" ]; then
  [ -f "$LINUX_BUNDLE" ] || { echo "!! LINUX_BUNDLE=$LINUX_BUNDLE does not exist" >&2; exit 1; }
  echo "==> Linux bundle:  $LINUX_BUNDLE (local, published as x86_64)"
elif [ -n "$LINUX_NAMES" ]; then
  echo "==> Linux assets:  $(tr '\n' ' ' <<<"$LINUX_NAMES")($LINUX_TAG)"
else
  echo "==> Linux assets:  none found (landing page keeps serving the previous flatpaks)"
fi

retry() {
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi
    echo "    retrying ($attempt/3 failed): $*" >&2
    sleep 3
  done
  return 1
}

echo "==> Downloading assets via gh..."
retry gh release download "$MAC_TAG" --repo "$REPO" -p "$MAC_NAME" -D "$WORKDIR" --clobber
retry gh release download "$WIN_TAG" --repo "$REPO" -p "$WIN_NAME" -D "$WORKDIR" --clobber
if [ -n "${LINUX_BUNDLE:-}" ]; then
  cp "$LINUX_BUNDLE" "$WORKDIR/clipboardSyncLinux-x86_64.flatpak"
elif [ -n "$LINUX_NAMES" ]; then
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    retry gh release download "$LINUX_TAG" --repo "$REPO" -p "$asset" -D "$WORKDIR" --clobber
    # Fixed per-arch names keep the landing page's links stable across versions.
    case "$asset" in
      *aarch64*|*arm64*) cp "$WORKDIR/$asset" "$WORKDIR/clipboardSyncLinux-aarch64.flatpak" ;;
      *) cp "$WORKDIR/$asset" "$WORKDIR/clipboardSyncLinux-x86_64.flatpak" ;;
    esac
  done <<<"$LINUX_NAMES"
fi
# Legacy alias for links published before the arch-explicit names existed.
[ -f "$WORKDIR/clipboardSyncLinux-x86_64.flatpak" ] \
  && cp "$WORKDIR/clipboardSyncLinux-x86_64.flatpak" "$WORKDIR/clipboardSyncLinux.flatpak"

# Fixed-name copies keep the landing page's links stable across version bumps.
cp "$WORKDIR/$MAC_NAME" "$WORKDIR/clipboardSyncMac.zip"
cp "$WORKDIR/$WIN_NAME" "$WORKDIR/clipboardSyncWin-Setup.exe"

echo "==> Fetching appcasts and rewriting enclosures to $PUBLIC_BASE"
for feed in appcast.xml win-appcast.xml; do
  gh api -H "Accept: application/vnd.github.raw" "/repos/$REPO/contents/$feed" > "$WORKDIR/$feed"
  # Point every enclosure at this server; only the newest item is ever downloaded by the
  # updaters, and its asset is uploaded below under the same (versioned) filename.
  sed -i '' -E "s#https://github.com/$REPO/releases/download/[^/\"]+/#$PUBLIC_BASE/#g" "$WORKDIR/$feed"
  grep -q "$PUBLIC_BASE/" "$WORKDIR/$feed" || { echo "!! $feed rewrite produced no local URLs" >&2; exit 1; }
done

echo "==> Uploading downloads to $DOWNLOADS_REMOTE"
UPLOADS=("$WORKDIR/$MAC_NAME" "$WORKDIR/$WIN_NAME"
    "$WORKDIR/clipboardSyncMac.zip" "$WORKDIR/clipboardSyncWin-Setup.exe"
    "$WORKDIR/appcast.xml" "$WORKDIR/win-appcast.xml")
for bundle in "$WORKDIR"/clipboardSyncLinux*.flatpak "$WORKDIR"/*.flatpak; do
  [ -f "$bundle" ] || continue
  case " ${UPLOADS[*]} " in *" $bundle "*) ;; *) UPLOADS+=("$bundle") ;; esac
done
scp "${UPLOADS[@]}" "$DOWNLOADS_REMOTE/"

echo "==> Uploading landing page to $SITE_REMOTE"
scp "$SCRIPT_DIR/landingPage/index.html" "$SITE_REMOTE/"
scp -r "$SCRIPT_DIR/landingPage/assets" "$SITE_REMOTE/"

# Verify everything actually serves: HTTP 200 and, for files we hold locally, a matching size.
verify() {
  local url="$1" local_file="${2:-}"
  local header code length
  header="$(curl -sIL -m 30 "$url")" || { echo "!! UNREACHABLE $url" >&2; return 1; }
  code="$(head -1 <<<"$header" | awk '{print $2}')"
  [ "$code" = "200" ] || { echo "!! HTTP $code for $url" >&2; return 1; }
  if [ -n "$local_file" ]; then
    length="$(grep -i '^content-length:' <<<"$header" | tail -1 | tr -d '[:space:]' | cut -d: -f2)"
    local expected
    expected="$(stat -f%z "$local_file")"
    [ "$length" = "$expected" ] || { echo "!! Size mismatch for $url (served ${length:-none}, expected $expected)" >&2; return 1; }
  fi
  echo "    ok $url"
}

echo "==> Verifying published resources"
failures=0
verify "$PUBLIC_SITE/" || failures=$((failures + 1))
verify "$PUBLIC_BASE/$MAC_NAME" "$WORKDIR/$MAC_NAME" || failures=$((failures + 1))
verify "$PUBLIC_BASE/$WIN_NAME" "$WORKDIR/$WIN_NAME" || failures=$((failures + 1))
verify "$PUBLIC_BASE/clipboardSyncMac.zip" "$WORKDIR/clipboardSyncMac.zip" || failures=$((failures + 1))
verify "$PUBLIC_BASE/clipboardSyncWin-Setup.exe" "$WORKDIR/clipboardSyncWin-Setup.exe" || failures=$((failures + 1))
verify "$PUBLIC_BASE/appcast.xml" "$WORKDIR/appcast.xml" || failures=$((failures + 1))
verify "$PUBLIC_BASE/win-appcast.xml" "$WORKDIR/win-appcast.xml" || failures=$((failures + 1))
for bundle in clipboardSyncLinux-x86_64.flatpak clipboardSyncLinux-aarch64.flatpak clipboardSyncLinux.flatpak; do
  if [ -f "$WORKDIR/$bundle" ]; then
    verify "$PUBLIC_BASE/$bundle" "$WORKDIR/$bundle" || failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "!! $failures resource(s) failed verification" >&2
  exit 1
fi

echo "==> Done. Published $MAC_TAG (mac) / $WIN_TAG (win):"
echo "    $PUBLIC_SITE/"
echo "    $PUBLIC_BASE/appcast.xml"
echo "    $PUBLIC_BASE/win-appcast.xml"
echo "    $PUBLIC_BASE/$MAC_NAME"
echo "    $PUBLIC_BASE/$WIN_NAME"
