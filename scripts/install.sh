#!/usr/bin/env bash
# Build bam in Release and install it to /Applications.
# The Release build keeps the production bundle id (me.harke.bam), so it runs
# independently of the Debug "bam dev" (me.harke.bam.dev) build.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Regenerating project"
xcodegen generate

DERIVED="$(mktemp -d)"
echo "==> Building Release"
xcodebuild \
  -project bam.xcodeproj \
  -scheme bam \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build

APP="$DERIVED/Build/Products/Release/bam.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build product not found at $APP" >&2
  exit 1
fi

DEST="/Applications/bam.app"
echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

rm -rf "$DERIVED"
echo "==> Done. Launch from /Applications/bam.app"
