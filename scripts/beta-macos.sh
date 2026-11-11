#!/bin/bash
# Build the macOS beta on a Mac, from the same commit as the ALPINE beta
# (scripts/beta.ps1 builds Android + Windows; a Mac build needs a Mac).
#
# Usage: scripts/beta-macos.sh <version, e.g. 1.4.18-beta> <build> [commit]
#
# Leaves $WORK/out/nasradio-macos.zip. Publishing is the same as the other
# beta files: copy it to the NAS updates dir as .new, verify, mv into place,
# then add "macos_size": <bytes> to version.json (the app only offers a Mac
# update when macos_size is non-zero).
set -euo pipefail

VERSION=${1:?version, e.g. 1.4.18-beta}
BUILD=${2:?build number}
COMMIT=${3:-HEAD}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/nasradio-beta-macos}
# Plain numeric version inside the app, like beta.ps1: older apps can't
# parse "18-beta". The channel rides in --dart-define.
PLAIN=${VERSION%%-*}

echo "building macOS $PLAIN ($BUILD) [$VERSION] from $COMMIT"
rm -rf "$WORK/src"
mkdir -p "$WORK/src" "$WORK/out"
git -C "$REPO" archive "$COMMIT" frontend | tar -x -C "$WORK/src"

cd "$WORK/src/frontend"
flutter pub get
flutter build macos --release --build-name "$PLAIN" --build-number "$BUILD" --dart-define CHANNEL=beta

APP=build/macos/Build/Products/Release/NASRadio.app
ZIP="$WORK/out/nasradio-macos.zip"
rm -f "$ZIP"
# ditto keeps the frameworks' symlinks; a plain zip breaks the app.
ditto -c -k --keepParent "$APP" "$ZIP"

SIZE=$(stat -f%z "$ZIP")
echo "MACOS-OK $VERSION build $BUILD from $(git -C "$REPO" rev-parse --short "$COMMIT") size $SIZE md5 $(md5 -q "$ZIP")"
