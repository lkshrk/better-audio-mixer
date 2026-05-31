#!/usr/bin/env bash
# Build BAMStreamDeck and drop it into the .sdPlugin bundle's bin/ for local
# sideload testing. Phase 5 / streamdeck.yml produces the signed universal build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/StreamDeck/me.harke.better-audio-mixer.sdPlugin"

cd "$ROOT/BamKit"
swift build -c release --product BAMStreamDeck

mkdir -p "$PLUGIN/bin"
cp ".build/release/BAMStreamDeck" "$PLUGIN/bin/BAMStreamDeck"
echo "Installed BAMStreamDeck -> $PLUGIN/bin/BAMStreamDeck"
echo "Sideload: symlink/copy $PLUGIN into ~/Library/Application Support/com.elgato.StreamDeck/Plugins/"
