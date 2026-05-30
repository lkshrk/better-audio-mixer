#!/bin/bash
# Install BAM.driver into the system HAL plug-in dir and restart coreaudiod.
# Requires admin (writes to /Library + restarts the audio daemon).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE="build/BAM.driver"
DEST="/Library/Audio/Plug-Ins/HAL"

if [ ! -d "$BUNDLE" ]; then
  echo "No $BUNDLE — run ./build.sh first." >&2
  exit 1
fi

echo "Installing $BUNDLE -> $DEST (sudo)…"
sudo rm -rf "$DEST/BAM.driver"
sudo cp -R "$BUNDLE" "$DEST/BAM.driver"
sudo chown -R root:wheel "$DEST/BAM.driver"

echo "Restarting coreaudiod (sudo)…"
sudo killall coreaudiod || sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || true

sleep 2
echo "Installed. Checking device list…"
# Guard the probe: a wedged coreaudiod makes system_profiler block forever.
# Use `timeout`/`gtimeout` if present, else a portable background-and-kill fallback.
if command -v timeout >/dev/null 2>&1; then
  timeout 8 bash -c 'system_profiler SPAudioDataType 2>/dev/null' | grep -i bam \
    || echo "(BAM not yet visible, or audio probe timed out — give coreaudiod a moment)"
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 8 bash -c 'system_profiler SPAudioDataType 2>/dev/null' | grep -i bam \
    || echo "(BAM not yet visible, or audio probe timed out — give coreaudiod a moment)"
else
  ( system_profiler SPAudioDataType 2>/dev/null >/tmp/bam_audioprobe.txt ) & probe_pid=$!
  ( sleep 8; kill "$probe_pid" 2>/dev/null ) & watch_pid=$!
  wait "$probe_pid" 2>/dev/null || true
  kill "$watch_pid" 2>/dev/null || true
  grep -i bam /tmp/bam_audioprobe.txt || echo "(BAM not yet visible, or audio probe timed out — give coreaudiod a moment)"
fi
