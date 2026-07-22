#!/usr/bin/env bash
# Publish the self-hosted update mirror and landing page at clipboardsync.fuzhuo.me.
#
# Default strategy (efficient):
#  1. Resolve the newest macOS / Windows / Linux assets in qiudaomao/clipboardSyncRelease.
#  2. On the mirror host (ssh), curl/wget each large binary from GitHub (or GH_PROXY),
#     skipping the download when a remote file already matches the expected size + sha256.
#  3. Create fixed-name aliases (clipboardSyncMac.zip, …) on the server with ln/cp.
#  4. Locally rewrite appcast.xml / win-appcast.xml enclosure URLs to this host and scp
#     those small files + the landing page (only things that must be authored here).
#  5. Verify with remote sha256sum (no re-download) and a cheap public HTTP HEAD.
#
# Fallback: --scp downloads assets to a local cache and scp's them (used if the host
# cannot reach GitHub, or when LINUX_BUNDLE supplies a local-only flatpak).
#
# Usage:
#   ./push.sh                 # remote-fetch large assets, scp appcasts + site, verify
#   ./push.sh --retry         # same, but skip remote downloads that already match hash/size
#   ./push.sh --upload-only   # alias of --retry
#   ./push.sh --scp           # force local download + scp of large assets
#   ./push.sh --verify-only   # remote hash + public HEAD only (no fetch/upload)
#   ./push.sh --help
#
# Environment:
#   PUSH_CACHE=/path     local cache for --scp / fallback (default: artifacts/push-cache)
#   LINUX_BUNDLE=/path   local x86_64 flatpak (forces scp for that file)
#   GH_PROXY=https://…   optional prefix for server-side downloads when GitHub is slow
#                        e.g. GH_PROXY=https://gh-proxy.com/
#   MIRROR_SSH=hk        ssh host (default: hk)
#   MIRROR_DIR=…         absolute path on the host (default under nginx static tree)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="qiudaomao/clipboardSyncRelease"
MIRROR_SSH="${MIRROR_SSH:-hk}"
MIRROR_DIR="${MIRROR_DIR:-/usr/share/nginx/html/static/clipboardSync}"
DOWNLOADS_DIR="$MIRROR_DIR/downloads"
SITE_REMOTE="$MIRROR_SSH:$MIRROR_DIR"
DOWNLOADS_REMOTE="$MIRROR_SSH:$DOWNLOADS_DIR"
PUBLIC_SITE="https://clipboardsync.fuzhuo.me"
PUBLIC_BASE="$PUBLIC_SITE/downloads"
CACHE_DIR="${PUSH_CACHE:-$SCRIPT_DIR/artifacts/push-cache}"
GH_PROXY="${GH_PROXY:-}"

MODE="full"          # full | retry | verify-only
TRANSFER="remote"    # remote | scp

usage() {
  cat <<'EOF'
Publish clipboardsync.fuzhuo.me downloads + landing page from clipboardSyncRelease.

  ./push.sh                 server-side curl/wget of release assets + scp appcasts/site
  ./push.sh --retry         skip assets already correct on the server (hash/size match)
  ./push.sh --upload-only   alias of --retry
  ./push.sh --scp           force local download + scp (fallback when server cannot pull)
  ./push.sh --verify-only   remote sha256 + public HEAD only
  ./push.sh --help

Environment:
  PUSH_CACHE=/path     local cache used by --scp / fallback (default: artifacts/push-cache)
  LINUX_BUNDLE=/path   optional local x86_64 flatpak (scp'd; not fetched from GitHub)
  GH_PROXY=https://…/  optional URL prefix for server-side GitHub downloads
  MIRROR_SSH=hk        ssh target
  MIRROR_DIR=/path     absolute web root for the site on the host
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --retry|--upload-only) MODE="retry"; shift ;;
    --verify-only) MODE="verify-only"; shift ;;
    --scp) TRANSFER="scp"; shift ;;
    -h|--help) usage ;;
    *) echo "!! unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "!! gh CLI is required (brew install gh && gh auth login)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "!! jq is required (brew install jq)" >&2; exit 1; }

mkdir -p "$CACHE_DIR"
WORKDIR="$CACHE_DIR"

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

local_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

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

# Public download URL for a release asset (optionally via GH_PROXY for the server).
asset_url() {
  local tag="$1" name="$2"
  local url="https://github.com/$REPO/releases/download/$tag/$name"
  if [ -n "$GH_PROXY" ]; then
    # Accept with or without trailing slash.
    echo "${GH_PROXY%/}/https://github.com/$REPO/releases/download/$tag/$name"
  else
    echo "$url"
  fi
}

# Print "size\tdigest" for asset $2 on tag $1. digest is the bare sha256 hex (no prefix), or empty.
asset_meta() {
  local tag="$1" name="$2"
  gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null \
    | jq -r --arg n "$name" '
        .assets[] | select(.name == $n)
        | [(.size|tostring), ((.digest // "") | sub("^sha256:"; ""))]
        | @tsv
      ' | head -1
}

# ---------------------------------------------------------------------------
# Discover newest per-platform assets
# ---------------------------------------------------------------------------
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
  echo "==> Linux bundle:  $LINUX_BUNDLE (local, will scp as x86_64)"
elif [ -n "$LINUX_NAMES" ]; then
  echo "==> Linux assets:  $(tr '\n' ' ' <<<"$LINUX_NAMES")($LINUX_TAG)"
else
  echo "==> Linux assets:  none found (landing page keeps serving the previous flatpaks)"
fi
echo "==> Mode:          $MODE  transfer=$TRANSFER  ssh=$MIRROR_SSH"
[ -n "$GH_PROXY" ] && echo "==> GH_PROXY:      $GH_PROXY"

# Collect "tag|name" rows for every large binary we need on the server.
ASSET_ROWS=()
ASSET_ROWS+=("$MAC_TAG|$MAC_NAME")
ASSET_ROWS+=("$WIN_TAG|$WIN_NAME")
if [ -z "${LINUX_BUNDLE:-}" ] && [ -n "$LINUX_NAMES" ]; then
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    ASSET_ROWS+=("$LINUX_TAG|$asset")
  done <<<"$LINUX_NAMES"
fi

# ---------------------------------------------------------------------------
# Remote helpers (run over ssh)
# ---------------------------------------------------------------------------
# Remote file size, or empty if missing.
remote_size() {
  local name="$1"
  ssh "$MIRROR_SSH" "stat -c%s $(printf %q "$DOWNLOADS_DIR/$name") 2>/dev/null" || true
}

remote_sha256() {
  local name="$1"
  ssh "$MIRROR_SSH" "sha256sum $(printf %q "$DOWNLOADS_DIR/$name") 2>/dev/null | awk '{print \$1}'" || true
}

# Download $name from $url on the server into DOWNLOADS_DIR, atomically.
# Skips when remote size (+ optional sha256) already match.
remote_fetch() {
  local name="$1" url="$2" expected_size="${3:-}" expected_sha="${4:-}"
  local remote_path="$DOWNLOADS_DIR/$name"
  local cur_size cur_sha

  cur_size="$(remote_size "$name")"
  if [ -n "$expected_size" ] && [ "$cur_size" = "$expected_size" ]; then
    if [ -n "$expected_sha" ]; then
      cur_sha="$(remote_sha256 "$name")"
      if [ "$cur_sha" = "$expected_sha" ]; then
        echo "    remote ok $name (sha256 match, $expected_size bytes)"
        return 0
      fi
      echo "    remote size ok but sha256 mismatch for $name; re-fetching" >&2
    else
      echo "    remote ok $name (size match, $expected_size bytes; no digest from GitHub)"
      return 0
    fi
  elif [ "$MODE" = "retry" ] || [ "$MODE" = "verify-only" ]; then
    if [ -n "$cur_size" ]; then
      echo "    remote $name present but size ${cur_size:-missing} != ${expected_size:-?} ; re-fetching" >&2
    fi
  fi

  echo "    remote fetch $name"
  # shellcheck disable=SC2029
  retry ssh "$MIRROR_SSH" bash -s -- "$url" "$remote_path" "$expected_size" <<'EOS'
set -euo pipefail
url="$1"; dest="$2"; expected_size="${3:-}"
tmp="${dest}.partial.$$"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT
# Prefer curl; fall back to wget. Follow redirects, fail on HTTP errors.
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 -o "$tmp" "$url"
elif command -v wget >/dev/null 2>&1; then
  wget -q --tries=3 --timeout=30 -O "$tmp" "$url"
else
  echo "!! neither curl nor wget on remote host" >&2
  exit 1
fi
if [ -n "$expected_size" ]; then
  actual="$(stat -c%s "$tmp")"
  if [ "$actual" != "$expected_size" ]; then
    echo "!! remote download size mismatch for $(basename "$dest"): got $actual expected $expected_size" >&2
    exit 1
  fi
fi
mv -f "$tmp" "$dest"
trap - EXIT
EOS

  if [ -n "$expected_sha" ]; then
    cur_sha="$(remote_sha256 "$name")"
    if [ "$cur_sha" != "$expected_sha" ]; then
      echo "!! remote sha256 mismatch for $name: got ${cur_sha:-none} expected $expected_sha" >&2
      return 1
    fi
    echo "    verified $name sha256=$expected_sha"
  fi
}

# Create fixed-name copies on the server (cheap, no re-download).
remote_alias() {
  local src="$1" dest="$2"
  # shellcheck disable=SC2029
  ssh "$MIRROR_SSH" "cp -f $(printf %q "$DOWNLOADS_DIR/$src") $(printf %q "$DOWNLOADS_DIR/$dest")"
  echo "    alias $dest <- $src"
}

# ---------------------------------------------------------------------------
# Local scp path (fallback / --scp / LINUX_BUNDLE)
# ---------------------------------------------------------------------------
cache_hit() {
  local path="$1" expected="${2:-}"
  [ -f "$path" ] || return 1
  [ -n "$expected" ] || return 0
  [ "$(file_size "$path")" = "$expected" ]
}

ensure_local_asset() {
  local tag="$1" name="$2" expected_size="${3:-}"
  local dest="$WORKDIR/$name"
  if cache_hit "$dest" "$expected_size"; then
    echo "    local cache hit $name (${expected_size:-?} bytes)"
    return 0
  fi
  echo "    local download $name from $tag"
  retry gh release download "$tag" --repo "$REPO" -p "$name" -D "$WORKDIR" --clobber
  if [ -n "$expected_size" ] && ! cache_hit "$dest" "$expected_size"; then
    echo "!! local download size mismatch for $name" >&2
    return 1
  fi
}

scp_file() {
  local local_path="$1" remote_name="$2" expected_sha="${3:-}"
  retry scp "$local_path" "$DOWNLOADS_REMOTE/$remote_name"
  if [ -n "$expected_sha" ]; then
    local got
    got="$(remote_sha256 "$remote_name")"
    if [ "$got" != "$expected_sha" ]; then
      echo "!! after scp, remote sha256 mismatch for $remote_name: got ${got:-none} expected $expected_sha" >&2
      return 1
    fi
    echo "    scp+sha256 ok $remote_name"
  else
    echo "    scp ok $remote_name"
  fi
}

# ---------------------------------------------------------------------------
# Place large assets on the server
# ---------------------------------------------------------------------------
# Expected metadata keyed by name via parallel arrays (bash 3.2-friendly).
META_NAMES=()
META_SIZES=()
META_SHAS=()
META_TAGS=()

record_meta() {
  local tag="$1" name="$2"
  local meta size sha
  meta="$(asset_meta "$tag" "$name")"
  size="$(cut -f1 <<<"$meta")"
  sha="$(cut -f2 <<<"$meta")"
  META_NAMES+=("$name")
  META_SIZES+=("$size")
  META_SHAS+=("$sha")
  META_TAGS+=("$tag")
}

lookup_meta() {
  # sets _size _sha _tag for name $1
  local name="$1" i
  _size=""; _sha=""; _tag=""
  for i in "${!META_NAMES[@]}"; do
    if [ "${META_NAMES[$i]}" = "$name" ]; then
      _size="${META_SIZES[$i]}"
      _sha="${META_SHAS[$i]}"
      _tag="${META_TAGS[$i]}"
      return 0
    fi
  done
  return 1
}

echo "==> Loading asset metadata (size + sha256 digest from GitHub)"
for row in "${ASSET_ROWS[@]}"; do
  tag="${row%%|*}"
  name="${row#*|}"
  record_meta "$tag" "$name"
  lookup_meta "$name"
  echo "    $name  size=${_size:-?}  sha256=${_sha:-<none>}"
done

if [ "$MODE" != "verify-only" ]; then
  if [ "$TRANSFER" = "remote" ]; then
    echo "==> Fetching large assets on $MIRROR_SSH (skip when hash/size already match)"
    remote_ok=1
    for row in "${ASSET_ROWS[@]}"; do
      tag="${row%%|*}"
      name="${row#*|}"
      lookup_meta "$name"
      url="$(asset_url "$tag" "$name")"
      if ! remote_fetch "$name" "$url" "$_size" "$_sha"; then
        echo "!! remote fetch failed for $name — will fall back to local scp for remaining work" >&2
        remote_ok=0
        TRANSFER="scp"
        break
      fi
    done
    if [ "$remote_ok" = 1 ]; then
      # Fixed-name landing-page aliases + legacy flatpak name.
      remote_alias "$MAC_NAME" "clipboardSyncMac.zip"
      remote_alias "$WIN_NAME" "clipboardSyncWin-Setup.exe"
      # Map whatever Linux assets we have to stable names.
      if [ -z "${LINUX_BUNDLE:-}" ] && [ -n "$LINUX_NAMES" ]; then
        while IFS= read -r asset; do
          [ -n "$asset" ] || continue
          case "$asset" in
            clipboardSyncLinux-aarch64.flatpak|clipboardSyncLinux-x86_64.flatpak) ;;
            *aarch64*|*arm64*) remote_alias "$asset" "clipboardSyncLinux-aarch64.flatpak" ;;
            *) remote_alias "$asset" "clipboardSyncLinux-x86_64.flatpak" ;;
          esac
        done <<<"$LINUX_NAMES"
        if ssh "$MIRROR_SSH" "test -f $(printf %q "$DOWNLOADS_DIR/clipboardSyncLinux-x86_64.flatpak")"; then
          remote_alias "clipboardSyncLinux-x86_64.flatpak" "clipboardSyncLinux.flatpak"
        fi
      fi
    fi
  fi

  if [ "$TRANSFER" = "scp" ]; then
    echo "==> Local download + scp of large assets"
    for row in "${ASSET_ROWS[@]}"; do
      tag="${row%%|*}"
      name="${row#*|}"
      lookup_meta "$name"
      ensure_local_asset "$tag" "$name" "$_size"
      # Prefer GitHub digest; else hash the local file and check after scp.
      sha="$_sha"
      if [ -z "$sha" ]; then
        sha="$(local_sha256 "$WORKDIR/$name")"
      fi
      scp_file "$WORKDIR/$name" "$name" "$sha"
    done
    # Aliases: scp the copies too (or cp on remote).
    remote_alias "$MAC_NAME" "clipboardSyncMac.zip"
    remote_alias "$WIN_NAME" "clipboardSyncWin-Setup.exe"
    if [ -n "${LINUX_BUNDLE:-}" ]; then
      scp_file "$LINUX_BUNDLE" "clipboardSyncLinux-x86_64.flatpak" "$(local_sha256 "$LINUX_BUNDLE")"
      remote_alias "clipboardSyncLinux-x86_64.flatpak" "clipboardSyncLinux.flatpak"
    elif [ -n "$LINUX_NAMES" ]; then
      while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        case "$asset" in
          clipboardSyncLinux-aarch64.flatpak|clipboardSyncLinux-x86_64.flatpak) ;;
          *aarch64*|*arm64*) remote_alias "$asset" "clipboardSyncLinux-aarch64.flatpak" ;;
          *) remote_alias "$asset" "clipboardSyncLinux-x86_64.flatpak" ;;
        esac
      done <<<"$LINUX_NAMES"
      if ssh "$MIRROR_SSH" "test -f $(printf %q "$DOWNLOADS_DIR/clipboardSyncLinux-x86_64.flatpak")"; then
        remote_alias "clipboardSyncLinux-x86_64.flatpak" "clipboardSyncLinux.flatpak"
      fi
    fi
  fi

  # LINUX_BUNDLE always scp's even in remote mode (not on GitHub).
  if [ -n "${LINUX_BUNDLE:-}" ] && [ "$TRANSFER" = "remote" ]; then
    echo "==> scp local LINUX_BUNDLE"
    scp_file "$LINUX_BUNDLE" "clipboardSyncLinux-x86_64.flatpak" "$(local_sha256 "$LINUX_BUNDLE")"
    remote_alias "clipboardSyncLinux-x86_64.flatpak" "clipboardSyncLinux.flatpak"
  fi
else
  echo "==> Skipping asset transfer (--verify-only)"
fi

# ---------------------------------------------------------------------------
# Appcasts (always rewritten locally — small; enclosures must point at this host)
# ---------------------------------------------------------------------------
echo "==> Fetching appcasts and rewriting enclosures to $PUBLIC_BASE"
for feed in appcast.xml win-appcast.xml; do
  retry gh api -H "Accept: application/vnd.github.raw" "/repos/$REPO/contents/$feed" > "$WORKDIR/$feed"
  sed -i '' -E "s#https://github.com/$REPO/releases/download/[^/\"]+/#$PUBLIC_BASE/#g" "$WORKDIR/$feed"
  grep -q "$PUBLIC_BASE/" "$WORKDIR/$feed" || { echo "!! $feed rewrite produced no local URLs" >&2; exit 1; }
done

if [ "$MODE" != "verify-only" ]; then
  echo "==> scp rewritten appcasts + landing page"
  app_sha="$(local_sha256 "$WORKDIR/appcast.xml")"
  win_sha="$(local_sha256 "$WORKDIR/win-appcast.xml")"
  scp_file "$WORKDIR/appcast.xml" "appcast.xml" "$app_sha"
  scp_file "$WORKDIR/win-appcast.xml" "win-appcast.xml" "$win_sha"
  retry scp "$SCRIPT_DIR/landingPage/index.html" "$SITE_REMOTE/"
  retry scp -r "$SCRIPT_DIR/landingPage/assets" "$SITE_REMOTE/"
  echo "    landing page uploaded"
fi

# ---------------------------------------------------------------------------
# Verify: remote sha256 (integrity) + public HEAD (nginx actually serves it)
# ---------------------------------------------------------------------------
verify_remote_hash() {
  local name="$1" expected_sha="$2" expected_size="${3:-}"
  local got size
  got="$(remote_sha256 "$name")"
  if [ -n "$expected_sha" ] && [ "$got" != "$expected_sha" ]; then
    echo "!! hash FAIL $name remote=${got:-none} expected=$expected_sha" >&2
    return 1
  fi
  if [ -n "$expected_size" ]; then
    size="$(remote_size "$name")"
    if [ "$size" != "$expected_size" ]; then
      echo "!! size FAIL $name remote=${size:-none} expected=$expected_size" >&2
      return 1
    fi
  fi
  if [ -n "$expected_sha" ]; then
    echo "    hash ok $name"
  else
    echo "    size ok $name (${expected_size:-?} bytes, no digest)"
  fi
}

verify_public_head() {
  local url="$1" expected_size="${2:-}"
  local header code length attempt
  for attempt in 1 2 3; do
    header="$(curl -sIL -m 30 "$url")" || {
      echo "    HEAD unreachable attempt $attempt/3: $url" >&2
      sleep 2
      continue
    }
    code="$(head -1 <<<"$header" | awk '{print $2}')"
    if [ "$code" != "200" ]; then
      echo "    HEAD HTTP $code attempt $attempt/3: $url" >&2
      sleep 2
      continue
    fi
    if [ -n "$expected_size" ]; then
      length="$(grep -i '^content-length:' <<<"$header" | tail -1 | tr -d '[:space:]' | cut -d: -f2)"
      if [ "$length" != "$expected_size" ]; then
        echo "    HEAD size mismatch attempt $attempt/3 $url served=${length:-none} expected=$expected_size" >&2
        sleep 2
        continue
      fi
    fi
    echo "    head ok $url"
    return 0
  done
  echo "!! HEAD FAIL $url" >&2
  return 1
}

echo "==> Verifying remote integrity (sha256 on server — no re-download)"
failures=0
for row in "${ASSET_ROWS[@]}"; do
  name="${row#*|}"
  lookup_meta "$name"
  verify_remote_hash "$name" "$_sha" "$_size" || failures=$((failures + 1))
done
# Aliases should match their sources.
lookup_meta "$MAC_NAME"
verify_remote_hash "clipboardSyncMac.zip" "$_sha" "$_size" || failures=$((failures + 1))
lookup_meta "$WIN_NAME"
verify_remote_hash "clipboardSyncWin-Setup.exe" "$_sha" "$_size" || failures=$((failures + 1))
# Appcasts: compare to the local rewritten bytes we just produced.
if [ -f "$WORKDIR/appcast.xml" ]; then
  verify_remote_hash "appcast.xml" "$(local_sha256 "$WORKDIR/appcast.xml")" "$(file_size "$WORKDIR/appcast.xml")" \
    || failures=$((failures + 1))
fi
if [ -f "$WORKDIR/win-appcast.xml" ]; then
  verify_remote_hash "win-appcast.xml" "$(local_sha256 "$WORKDIR/win-appcast.xml")" "$(file_size "$WORKDIR/win-appcast.xml")" \
    || failures=$((failures + 1))
fi

echo "==> Verifying public HEAD (HTTP 200 + Content-Length; body not downloaded)"
verify_public_head "$PUBLIC_SITE/" || failures=$((failures + 1))
lookup_meta "$MAC_NAME"
verify_public_head "$PUBLIC_BASE/$MAC_NAME" "$_size" || failures=$((failures + 1))
verify_public_head "$PUBLIC_BASE/clipboardSyncMac.zip" "$_size" || failures=$((failures + 1))
lookup_meta "$WIN_NAME"
verify_public_head "$PUBLIC_BASE/$WIN_NAME" "$_size" || failures=$((failures + 1))
verify_public_head "$PUBLIC_BASE/clipboardSyncWin-Setup.exe" "$_size" || failures=$((failures + 1))
if [ -f "$WORKDIR/appcast.xml" ]; then
  verify_public_head "$PUBLIC_BASE/appcast.xml" "$(file_size "$WORKDIR/appcast.xml")" || failures=$((failures + 1))
fi
if [ -f "$WORKDIR/win-appcast.xml" ]; then
  verify_public_head "$PUBLIC_BASE/win-appcast.xml" "$(file_size "$WORKDIR/win-appcast.xml")" || failures=$((failures + 1))
fi
for bundle in clipboardSyncLinux-x86_64.flatpak clipboardSyncLinux-aarch64.flatpak clipboardSyncLinux.flatpak; do
  size="$(remote_size "$bundle")"
  if [ -n "$size" ]; then
    verify_public_head "$PUBLIC_BASE/$bundle" "$size" || failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "!! $failures check(s) failed" >&2
  echo "   Retry without re-pulling good assets: ./push.sh --retry" >&2
  echo "   Force local scp path:               ./push.sh --scp --retry" >&2
  exit 1
fi

echo "==> Done. Published $MAC_TAG (mac) / $WIN_TAG (win) [mode=$MODE transfer=$TRANSFER]:"
echo "    $PUBLIC_SITE/"
echo "    $PUBLIC_BASE/appcast.xml"
echo "    $PUBLIC_BASE/win-appcast.xml"
echo "    $PUBLIC_BASE/$MAC_NAME"
echo "    $PUBLIC_BASE/$WIN_NAME"
