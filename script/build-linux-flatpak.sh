#!/usr/bin/env bash
# Builds the Linux flatpak bundles for x86_64 and aarch64 in Docker — no Linux
# machine needed. Uses the same container image as .github/workflows/linux-release.yml,
# so local and CI builds are identical. On Apple silicon the aarch64 build runs
# natively and the x86_64 build runs under emulation (slower, still fine).
#
# Output: artifacts/linux/clipboardSyncLinux-<arch>.flatpak
#
# Usage:
#   ./script/build-linux-flatpak.sh          # build both arches
#   ./script/build-linux-flatpak.sh x86_64   # build one arch
#   ./script/build-linux-flatpak.sh -u v0.1.20   # build both and upload to this
#                                                # repo's release tag (for push.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="ghcr.io/flathub-infra/flatpak-github-actions:kde-6.9"
MANIFEST="linux/packaging/io.github.qiudaomao.clipboardsync.yml"
APP_ID="io.github.qiudaomao.clipboardsync"
OUT_DIR="$REPO_ROOT/artifacts/linux"

UPLOAD_TAG=""
ARCHES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--upload) UPLOAD_TAG="$2"; shift 2 ;;
    x86_64|aarch64) ARCHES+=("$1"); shift ;;
    *) echo "usage: $0 [-u vX.Y.Z] [x86_64|aarch64 ...]" >&2; exit 1 ;;
  esac
done
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(aarch64 x86_64)

command -v docker >/dev/null || { echo "!! docker is required" >&2; exit 1; }
mkdir -p "$OUT_DIR"

for arch in "${ARCHES[@]}"; do
  platform="linux/amd64"
  [ "$arch" = "aarch64" ] && platform="linux/arm64"
  bundle="clipboardSyncLinux-$arch.flatpak"
  echo "==> Building $bundle (docker platform $platform)"
  docker run --rm --privileged --platform "$platform" \
    -v "$REPO_ROOT:/work" -w /work "$IMAGE" bash -ec "
      flatpak-builder --arch=$arch --force-clean --disable-rofiles-fuse \
        --state-dir=/tmp/flatpak-state \
        --repo=/tmp/flatpak-repo /tmp/flatpak-build $MANIFEST >/tmp/build.log 2>&1 \
        || { tail -40 /tmp/build.log >&2; exit 1; }
      tail -3 /tmp/build.log
      flatpak build-bundle --arch=$arch /tmp/flatpak-repo \"/work/artifacts/linux/$bundle\" $APP_ID master
      # Sanity check: the bundle must import cleanly and carry the right ref.
      ostree init --repo=/tmp/verify --mode=bare-user
      flatpak build-import-bundle /tmp/verify \"/work/artifacts/linux/$bundle\" >/dev/null
      ostree refs --repo=/tmp/verify | grep -q \"app/$APP_ID/$arch/master\" \
        || { echo '!! bundle ref/arch mismatch' >&2; exit 1; }
      echo \"    verified app/$APP_ID/$arch/master\"
    "
  ls -la "$OUT_DIR/$bundle"
done

if [ -n "$UPLOAD_TAG" ]; then
  echo "==> Uploading bundles to qiudaomao/clipboardSync $UPLOAD_TAG"
  for arch in "${ARCHES[@]}"; do
    gh release upload "$UPLOAD_TAG" "$OUT_DIR/clipboardSyncLinux-$arch.flatpak" \
      --repo qiudaomao/clipboardSync --clobber
  done
  echo "==> Done. Run ./script/push.sh to publish the mirror."
fi
