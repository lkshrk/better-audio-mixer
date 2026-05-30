#!/bin/bash
# Build the BAM AudioServerPlugin into BAM.driver (ad-hoc signed, dev only).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE="build/BAM.driver"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp Info.plist "$BUNDLE/Contents/Info.plist"
cp BAM.icns  "$BUNDLE/Contents/Resources/BAM.icns"

clang -bundle -O2 -fobjc-arc \
  -mmacosx-version-min=12.0 \
  -DkDriver_Name='"BAM"' \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name='"BAM"' \
  -DkPlugIn_BundleID='"me.harke.bam.driver"' \
  -DkPlugIn_Icon='"BAM.icns"' \
  -DkManufacturer_Name='"BAM"' \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework Accelerate \
  -o "$BUNDLE/Contents/MacOS/BAM" \
  BAMDriver.c

# Ad-hoc code signature so coreaudiod will load it on a dev machine.
codesign --force --sign - "$BUNDLE"

echo "Built $BUNDLE"
codesign -dv "$BUNDLE" 2>&1 | head -3
