#!/usr/bin/env bash
# Build, install, and restart the local Stream Deck plugin for fast hardware QA.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/StreamDeck/me.harke.better-audio-mixer.sdPlugin"
INSTALL_DIR="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/me.harke.better-audio-mixer.sdPlugin"
BUILT_BIN="$PLUGIN/bin/BAMStreamDeck"
INSTALLED_BIN="$INSTALL_DIR/bin/BAMStreamDeck"
STREAM_DECK_LOG="$HOME/Library/Logs/ElgatoStreamDeck/StreamDeck.log"
RUN_TESTS=1

usage() {
  cat <<'EOF'
Usage: scripts/install-streamdeck-plugin.sh [--skip-tests]

Runs the local Stream Deck plugin QA/install loop:
  1. swift test --package-path BamKit
  2. StreamDeck/build-plugin.sh
  3. copy the .sdPlugin bundle into Stream Deck's Plugins directory
  4. verify built/installed BAMStreamDeck hashes match
  5. restart the BAMStreamDeck helper and confirm relaunch

Options:
  --skip-tests   Build/install/restart without running the package tests.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

find_helper_pids() {
  ps -axo pid=,command= | awk -v bin="$INSTALLED_BIN" '
    {
      pid = $1
      sub(/^ *[0-9]+ /, "")
      if (index($0, bin) == 1) {
        print pid
      }
    }
  '
}

stream_deck_log_line_count() {
  if [[ -f "$STREAM_DECK_LOG" ]]; then
    wc -l < "$STREAM_DECK_LOG" | awk '{ print $1 }'
  else
    echo 0
  fi
}

plugin_was_disabled_since() {
  local start_line="$1"
  [[ -f "$STREAM_DECK_LOG" ]] || return 1
  tail -n +"$((start_line + 1))" "$STREAM_DECK_LOG" \
    | grep -F "[me.harke.better-audio-mixer] Plugin is unstable" >/dev/null 2>&1
}

wait_for_stable_helper() {
  local start_line="$1"
  local timeout_ticks=40
  local stable_ticks_required=6
  local stable_ticks=0
  local last_pids=""
  local pids joined

  for _ in $(seq 1 "$timeout_ticks"); do
    sleep 0.5
    if plugin_was_disabled_since "$start_line"; then
      echo "Stream Deck disabled the plugin as unstable during relaunch." >&2
      return 2
    fi

    pids=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(find_helper_pids)
    if [[ "${#pids[@]}" -eq 0 ]]; then
      stable_ticks=0
      last_pids=""
      continue
    fi

    joined="${pids[*]}"
    if [[ "$joined" == "$last_pids" ]]; then
      stable_ticks=$((stable_ticks + 1))
    else
      last_pids="$joined"
      stable_ticks=1
    fi

    if [[ "$stable_ticks" -ge "$stable_ticks_required" ]]; then
      echo "relaunched and stable: $joined"
      return 0
    fi
  done

  echo "BAMStreamDeck did not stay alive within 20 seconds." >&2
  return 1
}

if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "==> Testing BamKit"
  swift test --package-path "$ROOT/BamKit"
fi

echo "==> Building Stream Deck plugin"
"$ROOT/StreamDeck/build-plugin.sh"

echo "==> Installing plugin bundle"
mkdir -p "$(dirname "$INSTALL_DIR")"
/usr/bin/ditto "$PLUGIN" "$INSTALL_DIR"

echo "==> Verifying installed helper hash"
built_hash="$(shasum -a 256 "$BUILT_BIN" | awk '{ print $1 }')"
installed_hash="$(shasum -a 256 "$INSTALLED_BIN" | awk '{ print $1 }')"
if [[ "$built_hash" != "$installed_hash" ]]; then
  echo "Hash mismatch:" >&2
  echo "  built:     $built_hash  $BUILT_BIN" >&2
  echo "  installed: $installed_hash  $INSTALLED_BIN" >&2
  exit 1
fi
echo "hash: $built_hash"

log_start_line="$(stream_deck_log_line_count)"
pids=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && pids+=("$pid")
done < <(find_helper_pids)
if [[ "${#pids[@]}" -gt 0 ]]; then
  echo "==> Restarting BAMStreamDeck: ${pids[*]}"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
else
  echo "==> BAMStreamDeck is not currently running"
fi

echo "==> Waiting for Stream Deck to relaunch a stable helper"
if wait_for_stable_helper "$log_start_line"; then
  echo "done"
  exit 0
fi

echo "If Stream Deck is closed, open it and it should load: $INSTALL_DIR" >&2
exit 1
