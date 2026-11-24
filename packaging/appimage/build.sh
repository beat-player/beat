#!/usr/bin/env bash
# Packs a Linux beat executable as an AppImage. The AppImage holds the same single executable the
# release zip does: beat links nothing beyond what every desktop has (Vulkan, X11, ALSA, libc),
# and the native modules it carries are unpacked into the temporary directory at start, so the
# image needs no libraries of its own.
#
#   packaging/appimage/build.sh <beat executable> <x86_64|aarch64> <output.AppImage>
#
# appimagetool is downloaded when it is not on PATH. It is itself an AppImage, run here without
# FUSE, which CI containers and many build machines do not have.
set -euo pipefail

if [ $# -ne 3 ]; then
	echo "usage: $0 <beat executable> <x86_64|aarch64> <output.AppImage>" >&2
	exit 2
fi

binary=$(realpath "$1")
arch=$2
output=$(realpath -m "$3")
here=$(cd "$(dirname "$0")" && pwd)
icons="$here/../../packages/beat/assets"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
appdir="$work/beat.AppDir"

install -Dm755 "$binary" "$appdir/usr/bin/beat"
install -Dm644 "$here/beat.desktop" "$appdir/beat.desktop"
install -Dm644 "$here/beat.desktop" "$appdir/usr/share/applications/beat.desktop"
install -Dm644 "$icons/icon-256.png" "$appdir/beat.png"
install -Dm644 "$icons/icon-256.png" "$appdir/usr/share/icons/hicolor/256x256/apps/beat.png"
install -Dm644 "$icons/icon.svg" "$appdir/usr/share/icons/hicolor/scalable/apps/beat.svg"
ln -s beat.png "$appdir/.DirIcon"
ln -s usr/bin/beat "$appdir/AppRun"

tool=$(command -v appimagetool || true)
if [ -z "$tool" ]; then
	tool="$work/appimagetool"
	curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$(uname -m).AppImage"
	chmod +x "$tool"
fi

APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$arch" "$tool" --no-appstream "$appdir" "$output"
