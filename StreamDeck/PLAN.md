# BAM Stream Deck Support — Implementation Plan

Status: **design locked, no code written yet.** Produced via `/grill-me` interview.
Implementation starts only on explicit "implement Phase 1" signal.

---

## 1. Architecture

- **Official Elgato plugin that coexists** with BAM — NOT direct HID. BAM stays the
  audio authority; the plugin is a thin remote control.
- **Transport: Unix domain socket.** `~/Library/Application Support/me.harke.bam/control.sock`,
  mode `0600`. BAM is not sandboxed (entitlements: only `device.audio-input`), so the
  UDS path and `NSWorkspace` launch are allowed. `0600` = same-user auth, no token needed.
- **Plugin stack: Swift executable** sharing a `BamControlKit` SPM module with the app.
  `URLSessionWebSocketTask` (built-in) speaks the Elgato WS protocol — hand-rolled, no
  official Swift SDK. Property Inspector is HTML/JS (always — runs in Elgato webview).

## 2. ControlServer (lives in BamControlKit)

- New library target `BamControlKit` in BamKit (deps: BamCore).
- `MixerControl` protocol; `ConsoleViewModel` conforms (mirrors AudioEngineProtocol /
  MockAudioEngine pattern). `MockMixerControl` for headless tests.
- Socket on a background queue (DispatchSource / POSIX), hops to `@MainActor` to read
  `model.snapshot` and to mutate via the protocol.
- App wires the server up in `start()`.

### Connection / fan-out model

- Server holds a `Set<Client>`; supports **N concurrent clients** (two Stream Decks,
  plugin reconnects).
- **Broadcast to all clients, no per-mix subscription filtering** (N tiny; plugin filters
  client-side by the `mix.id` each key/dial cares about).
- **No subscribe message.** Hello handshake → server streams.
- **Full `state` snapshot on connect** (every mix + master: id, name, emoji, pos, pct,
  muted, level), then deltas. Without it a fresh plugin shows blank keys when audio is
  silent (no deltas ever arrive).
- Dead clients pruned on write `EPIPE`.

## 3. Wire protocol

- **NDJSON** — one JSON object per line. Flat envelope, `t` = type, no nested `data`.
- **Versioned hello handshake.** `hello.v=1` → `hello-ack.v=1`. Mismatch → `{"t":"error","code":"version"}`
  then close; plugin shows "update" alert. Unknown `t` / unknown fields ignored (forward-compat).
- **Split hot vs cold frames:** `meter` (level-only, ~30fps, high churn) separate from
  `delta` (pos/mute change, event-driven, rare). Keeps the hot frame tiny.
- **`level` stays raw dB float** on the wire (e.g. -18.3); plugin maps dB→0–100 using
  `RMSMeter.floorDB` as 0. Position/percent = perceptual taper values for the slider bar.
  Two domains, two bars.

### Client → server

```
{"t":"hello","v":1,"client":"streamdeck"}
{"t":"cmd","op":"setPos","mix":"m-game","pos":0.62}
{"t":"cmd","op":"nudgePos","mix":"m-game","delta":0.03}
{"t":"cmd","op":"setMuted","mix":"m-game","muted":true}
{"t":"cmd","op":"toggleMuted","mix":"m-game"}
{"t":"cmd","op":"setMasterPos","pos":0.5}
{"t":"cmd","op":"nudgeMasterPos","delta":0.03}
{"t":"cmd","op":"setMasterMuted","muted":true}
{"t":"listMixes"}
```

### Server → client

```
{"t":"hello-ack","v":1,"app":"BAM","build":"1.0.0"}
{"t":"state","mixes":[{"id":"m-game","name":"Game","emoji":"🎮","pos":0.62,"pct":62,"muted":false,"level":-18.3}],"master":{"pos":0.5,"pct":50,"muted":false,"level":-22.1}}
{"t":"meter","mixes":[{"id":"m-game","level":-15.2}],"master":{"level":-19.0}}
{"t":"delta","mix":"m-game","pos":0.70,"pct":70,"muted":false}
{"t":"removed","mix":"m-game"}
{"t":"mixes","mixes":[{"id":"m-game","name":"Game","emoji":"🎮"}]}
{"t":"error","code":"unknown_mix","mix":"m-zzz"}
```

## 4. Level domain

- **Perceptual position 0–1 (+percent) on the wire.** Move `AudioTaper`
  (cube taper, exp 3.0) from `App/ConsoleTheme.swift` → `BamCore`.
- ControlServer converts device position→gain via the cube taper; **master passes
  through linear** (hardware scalar already perceptual; `setOutputVolume` takes raw 0–1).
- Steps: key nudge ±5% position; dial ±~3% position/detent (PI step-size configurable).

## 5. SD+ encoder LCD (200×100)

Elgato provides 6 **built-in** layouts; bars need no custom drawing — `setFeedback`
updates a bar/gbar by **number**, text/pixmap by **string** (keyed by layout `key`).

- Built-ins: `$X1` (title+icon), `$A1` (+value), `$B1` (+single bar), `$B2` (+gradient
  gbar), `$C1` (two bars), `$A0` (full canvas).
- **Three dial styles** swapped via `setFeedbackLayout` (PI dropdown, default Combined):
  - **Volume Slider** = `$B1` (slider bar only).
  - **Level Meter** = `$B2` (gradient gbar only).
  - **Combined** = custom `layouts/band.json` (two stacked full-width bars).

`layouts/band.json`:
```json
{
  "$schema":"https://schemas.elgato.com/streamdeck/plugins/layout.json",
  "id":"band",
  "items":[
    {"key":"title","type":"text","rect":[16,8,168,20],"font":{"size":14,"weight":600},"alignment":"center"},
    {"key":"value","type":"text","rect":[16,28,168,30],"font":{"size":24,"weight":700},"alignment":"center"},
    {"key":"slider","type":"bar","rect":[16,62,168,10],"value":0,"subtype":4,"border_w":0,"bar_bg_c":"#4A9EFF"},
    {"key":"meter","type":"gbar","rect":[16,76,168,10],"value":0,"subtype":4,"bar_h":8,"border_w":0,"bar_bg_c":"0:#ff0000,0.33:#a6d4ec,0.66:#f4b675,1:#00ff00"}
  ]
}
```

- `slider` = blue `bar`, fader position 0–100. `meter` = gradient `gbar`, live RMS 0–100
  (dB→0–100 mapped **in the plugin**, not the server).
- Per-frame: `setFeedback {"title":"Game","value":"62%","slider":62,"meter":48}`.
- Mute → `value:"MUTED"`, `meter:0`, slider unchanged (shows return point).
- **Encoder redraw throttled below the source period** (~25ms guard for a ~30fps
  source) so burst frames are dropped without aliasing steady 33ms meter frames.

## 6. Keys

- **No per-frame live meter refresh on keys.** Keys use full base64 PNG `setImage`
  payloads, so they refresh on state/setting changes and dedupe meter artwork to
  the visible segmented states.

## 7. Actions (manifest)

UUID prefix `me.harke.bam.streamdeck.` — **6 actions**, direction/step folded into PI
(matches Wave Link's single "Adjust" action):

**Keypad:**
- `.deviceVolume` — PI: mix + step + direction (Up/Down/Set). Press = nudge/set.
- `.deviceMute` — PI: mix. Press = toggle mute; icon reflects state.
- `.masterVolume` — PI: step + direction. Press = nudge master.
- `.masterMute` — Press = toggle master mute.

**Encoder:**
- `.deviceDial` — PI: mix + step + style. Rotate=adjust, press=mute, band LCD.
- `.masterDial` — PI: step + style. Rotate=master adjust, press=master mute.

Manifest: `SDKVersion:2`, `Software.MinimumVersion:"6.5"`, `OS:[{mac, 12}]`,
`CodePath` → Swift binary, **no Node**. Icons: SF-symbol-style PNG 20×20/40×40,
white on transparent; master tinted.

## 8. Property Inspector ↔ device list

PI (webview JS) can't open the UDS itself — goes through the plugin.

- **Write-through `globalSettings` cache (a) + live refresh (b):**
  1. Plugin mirrors newest mix list from `state`/`delta` into Stream Deck `globalSettings`.
  2. PI on load reads `globalSettings` → instant dropdown (works offline → greyed "BAM offline").
  3. PI also fires `sendToPlugin {"t":"listMixes"}`; plugin → BAM → returns via
     `sendToPropertyInspector {"t":"mixes",...}`; PI refreshes live.
- Binding stored in **action settings**: `{mix:"m-game", step:0.03, style:"combined", direction:"set"}`.
- Bind by **stable `mix.id`.** If id vanishes from later `state` → key/dial greyed,
  title "(removed)". Rename in BAM → `delta` carries new name → plugin pushes
  `setTitle`/`setFeedback`; binding survives.

## 9. BAM offline handling

- Plugin **auto-launches** BAM via `NSWorkspace` bundle-id lookup: prefer release
  `me.harke.bam`, fall back `me.harke.bam.dev`.
- Connect **eagerly on `willAppear`**, retry with backoff.

## 10. Package layout

Extend BamKit; new top-level `StreamDeck/` for plugin assets.

```
BamKit/
  Package.swift            # + BamControlKit lib, + BAMStreamDeck exe, + BamControlKitTests
  Sources/BamControlKit/   # MixerControl protocol, ControlServer, NDJSON, framing
  Sources/BAMStreamDeck/   # Swift plugin exe (WS client + UDS client)
StreamDeck/
  me.harke.better-audio-mixer.sdPlugin/   # manifest.json, PI html/js, layouts/band.json, icons, bin/
  PLAN.md                  # this file
```
App deps += BamControlKit.

## 11. CI / distribution

- **Separate workflow `streamdeck.yml`**, triggered on same `v*` tags as release.yml,
  reuses DEVID cert + notary secrets. (Tag pushes don't match `branches:[main]`, so no
  double-run with ci.yml.)
- **Universal binary via SwiftPM** double `--arch`:
  `swift build -c release --arch arm64 --arch x86_64 --product BAMStreamDeck` (SwiftPM lipos).
- Assemble `.sdPlugin`, drop binary into `bin/`.
- **Sign** Developer-ID + hardened runtime (same identity as app):
  `codesign --force --options runtime --timestamp --sign "$DEVID" .../bin/BAMStreamDeck`.
- **Notarize** zipped plugin (`notarytool submit --wait`). Loose-exe staple unsupported →
  rely on online notarization check; document "first launch needs net".
- Pack `.streamDeckPlugin` (Elgato DistributionTool), attach to the same GitHub release
  as a separate asset.
- **v1 = sideload** (user double-clicks `.streamDeckPlugin`); Marketplace submission later
  (manual, needs the universal binary — already produced).

---

## Phase order (each phase shippable + testable without the next)

**Phase 1 — ControlServer core (headless, pure unit tests; no hardware).**
- Add `BamControlKit` lib (deps BamCore). Move `AudioTaper` ConsoleTheme → BamCore.
- `MixerControl` protocol; `ConsoleViewModel` conforms; `MockMixerControl`.
- UDS server (DispatchSource/POSIX, bg queue, MainActor hops), NDJSON framing,
  hello/ack/version, `state`/`meter`/`delta`/`removed`, cmd parsing, broadcast-all,
  EPIPE prune. Timer snapshot diff ~12fps. App wires server on `start()`.
- Tests: handshake, version-mismatch, cmd→mock mutation, diff emits changed-only,
  multi-client fan-out, dead-client prune. **Green = Phase 1 done.**

**Phase 2 — Swift plugin skeleton + connectivity.**
- `BAMStreamDeck` exe (deps BamControlKit). Elgato WS register
  (`-port/-pluginUUID/-registerEvent`). UDS client + backoff + NSWorkspace auto-launch.
- `willAppear`→connect eager; `hello`; consume `state`. No actions yet — proves the
  WS↔UDS bridge, logs frames.

**Phase 3 — Keys.**
- 4 keypad actions. `keyDown`→cmd. `setImage`/`setTitle` from state/delta. PI html +
  device dropdown (`listMixes` + globalSettings cache).

**Phase 4 — Dials.**
- 2 encoder actions. `dialRotate`→nudge, `dialDown`→mute, `setFeedback` band,
  `setFeedbackLayout` style swap. 8fps throttle.

**Phase 5 — Package + CI.**
- `streamdeck.yml`, universal build, sign/notarize, `.streamDeckPlugin` asset. Icons.
  Sideload docs.

**Phase 6 — later, not v1.**
- Keys live-meter PNG, Marketplace submission, Set-to-% with fade.

---

## Reference

- Stream Deck SDK dials/layouts: https://docs.elgato.com/streamdeck/sdk/guides/dials/
- Wave Link plugin overview: https://help.elgato.com/hc/en-us/articles/10521603097741-Wave-Link-2-Stream-Deck-Plugin-Overview
- HID protocol (if ever direct): https://docs.elgato.com/streamdeck/hid/
