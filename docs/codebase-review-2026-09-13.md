# Codebase review — 2026-09-13

Scope: full first-party tree at `e69e58f` (v1.0.7 + two commits). Five parallel read-only
reviews (AudioEngine, BAMDriver, App, BamCore/BamControlKit/build, BAMStreamDeck), then
lead spot-verification of every top-tier claim against source. Baseline: BamKit builds
clean, 163 tests pass, 2 skipped.

Severity legend: **C** critical, **H** high, **M** medium, **L** low.
"Verified" = lead re-read the cited lines. Reviewer-only claims are marked *(reviewer)*.

> **Status (same day):** all findings below were implemented on top of `e69e58f`, verified by
> `make test` (BamKit 189 XCTest + 73 Swift Testing, App 76 tests, python self-tests).
> Deliberately not done: flipping tap drift compensation for the cross-device case (§3.1 #1 —
> rate mismatch + frame-divergence counters added instead; measure first); retiring
> `MixDestination.virtualSlot` (live model concept, driver reviewer was wrong); Stream Deck
> WebSocket send coalescing (throttles bound sends already). Benign residual: Xcode explicit-modules
> notice "'BamCore' is missing a dependency on 'Yams'" once the test bundle became app-hosted.

## 1. Executive summary

The real-time path is clean. The IOProc (`RouterAggregate.swift:465-585`) has no
allocation, locks, logging, dispatch or actor hops; every software gain step is ramped
(5 ms `GainRamp`, 2048-frame fade-in). Audio quality problems are not in the DSP.

Lag and quality risk sit on the **control side**:

1. **Faders are silent while dragged.** `Fader` only calls `onCommit` on mouse-up, so
   neither router gain nor hardware volume moves until release. This is the single
   biggest "it feels laggy" cause and is a small fix. *(verified)*
2. **The engine actor blocks on HAL writes.** Confirmed volume/mute writes wait up to
   0.5 s per channel element under one global lock, on the same actor that serves
   meters and gain updates. Router build (taps + aggregate + spin-wait readiness) also
   runs synchronously on that actor. *(verified)*
3. **Every gain change writes `bam.yaml` synchronously on the main actor.** A Stream
   Deck dial sweep = dozens of YAML encodes + atomic file writes per second.
   *(verified)*
4. **Possible clock-domain split since v1.0.7.** Taps bind to the macOS default output
   device, the aggregate's main sub-device is the BAM output, drift compensation is 0
   and no rate check exists. If those are different hardware clocks, expect periodic
   drop/dup glitches. Needs measurement before any change (see §3.1). *(code verified,
   audible impact unverified)*
5. **Control server can deadlock the app.** Accepted sockets stay blocking; one client
   that stops reading stalls `bgQueue`, all other clients, and the main actor via
   `diagnosticsSnapshot()`'s `bgQueue.sync`. *(verified: no `O_NONBLOCK`/`SO_SNDTIMEO`
   anywhere in `ControlServer.swift`)*
6. **BAMDriver is dead code** (4334 lines of C, GPL-3, last client deleted in
   `55d9bcb` 2026-06-06). Delete it. *(verified)*
7. **Stream Deck ship blocker:** manifest says `MinimumVersion: "12"`, binary targets
   macOS 14.4. *(verified)*

Rough dead-code total across the tree: ~600 lines Swift + the whole driver.

## 2. Priority actions (ordered by payoff / effort)

| # | Action | Effort | Payoff |
|---|--------|--------|--------|
| 1 | `Fader`: add `onChange`, drive `updateRouterGains` / output volume live during drag, persist on release | S | Perceived lag, biggest |
| 2 | Debounce `persist()` (~300 ms, flush on exit) | S | Main-thread stalls, disk churn |
| 3 | Move confirmed HAL writes off the engine actor to a serial hardware executor | M | Meters + gains stop freezing during master drags |
| 4 | Build router (taps, aggregate, readiness wait) off-actor, commit via generation check (pattern already in `checkRouterHealth`) | M | Meters stop freezing for seconds on rebuild |
| 5 | `ControlServer`: non-blocking fds, drop-frame on `EAGAIN`, evict after N drops; cap clients; cap read buffer | S | Removes an app-hang path |
| 6 | Fix Stream Deck manifest `MinimumVersion` → `14.4` | XS | Ship blocker |
| 7 | Measure capture-vs-render clock split; add rate check + divergence counter to `HealthSnapshot` | M | Quality (conditional) |
| 8 | Delete `BAMDriver/`, `App/MeterBar.swift`, dead view-model API, dead Stream Deck drawers (§7) | S | ~5k lines gone, GPL subtree gone |
| 9 | Leaf-view meters + `SourceApp: Equatable` + hoist `Color(hex:)` out of `Meter.cells` | S | Main-thread CPU at 30 Hz |
| 10 | Retro key: quantize to ~24 steps + throttle to ~12 fps; dial throttle 1/15 s | S | Stream Deck WebSocket flood |
| 11 | Exit path: `applicationShouldTerminate` → `.terminateLater` instead of 1 s semaphore; exit-muted flag | M | Device-left-muted hazard |

## 3. AudioEngine (`BamKit/Sources/AudioEngine`)

### 3.1 Findings

- `RouterAggregate.swift:403-414` — **H** — quality — Taps bind to capture UID
  (macOS default output), aggregate main sub-device is `outputUID`. When they differ
  there are two clocks, yet `kAudioSubTapDriftCompensationKey: 0` and no comparison
  of `tap.proc.format.mSampleRate` to `outputLayout.sampleRate`. **Caution:** the
  cerebrum rule "drift comp = 1 destroys bass" was measured same-device. Do not flip it
  blindly. First: log/assert rate equality in `startIO`, add input-vs-output frame
  divergence counter, measure with the two devices actually different. Only then decide
  between drift comp on the tap entries (cross-device only) or a documented constraint.
- `CoreAudioEngine.swift:524-526` (+`:462-464`, `:307-323`, `:375-402`) — **H** — lag —
  `setOutputVolumeChecked`, `outputMuted`, `restoreOutputDeviceState` run confirmed HAL
  writes on the engine actor. Each element waits on a semaphore ≤0.5 s
  (`CoreAudioProperty.swift:94-98`), N elements on multichannel devices, all under one
  global `NSLock` (`CoreAudioProperty.swift:24-42`; a second forced write inside the
  lock at `:29`). `routerSnapshot` and `updateRouterGains` queue behind it. Load-analysis
  rec #2 not implemented. *(verified)*
- `CoreAudioEngine.swift:808-1018` — **H** — lag — `startRouter` is a 210-line
  synchronous actor method covering tap creation, aggregate creation, `AudioDeviceStart`
  and `waitUntilReady` (spins `Thread.sleep(1 ms)` ≤0.5 s, `RouterAggregate.swift:102-110`).
  Load doc measured 4.6 s for `agg.start`. *(reviewer)*
- `CoreAudioEngine.swift:741-778` — **M** — HAL load — `canKeepCurrentRouter` runs on
  every `routerEvent`: full `allProcesses()` (3 reads per process), output resolve,
  tap capture UID reads, format reads. BAM's own tap/aggregate creation fires
  `kAudioHardwarePropertyDevices`, so each rebuild triggers its own preflight. No
  debounce. Fix: ~250 ms debounce; short-circuit on default-output UID + device-list
  hash before the process scan. *(reviewer)*
- `CoreAudioEngine.swift:1086-1097` — **M** — HAL load — 2 s health scan calls
  `allProcesses()` (PID + bundleID + isRunningOutput per process) while
  `expectedAudibleSourceIDs` needs only running + bundleID; the view model polls
  `playingBundleIDs` + `outputDevices` every 2 s independently. Fix: shared
  `ProcessSnapshot` cache, ~1 s TTL, invalidated by the ProcessObjectList listener.
- `RouterAggregate.swift:451-455, 510-516`, `RouterInputMixer.swift:7, 65` — **M** —
  RT — IOProc indexes Swift arrays of class refs (`[AtomicFloat]`,
  `[ManagedAtomic<Int>]`, `[AtomicStereoGain]`): bounds check + retain/release per tap
  per callback; `outputLayout` struct with `[Int]` passed by value at `:480`. No lock or
  malloc, but avoidable ARC on the RT thread. Fix: `UnsafeAtomic` cells in one
  `UnsafeMutablePointer` owned by `RouterInputMixer`; copy `bufferChannels` to raw
  pointer at `startIO`.
- `NativePeakLimiter.swift:93-98, 107-132` — **M** — RT perf — three scalar per-frame
  passes with optional chaining on `right?[...]`, `abs`/`isFinite` per sample, and
  class-property mutation (`guardedSamples &+= 1`) inside `sanitize` → dynamic
  exclusivity checks per sample. ~3× the vDSP mix cost. Fix: `vDSP_mmov`/`cblas_scopy`
  strided copy, `vDSP_maxmgv` for ceiling, accumulate counts in locals.
- `NativePeakLimiter.swift:48-50, 63-67` — **M** — latency — AUPeakLimiter
  `delayFrames` added always, even single-app never-clipping case. Value only logged.
  Fix: surface in `AudioDiagnostics.limiterDelayFrames` + latency doc; test whether a
  shorter attack shortens reported latency. A bypass switch is not an option (delay-line
  discontinuity).
- `CoreAudioEngine.swift:1444-1457` — **M** — concurrency — `routerSnapshots()` overwrites
  `routerSamplerTask` without cancelling the previous one. Same bug in
  `MockAudioEngine.swift:219-234`.
- `ChangeListener.swift:35` — **M** — errors — `AudioObjectAddPropertyListenerBlock`
  status discarded; failed registration = silent `routerEvents` forever. Fix: log, expose
  `isActive`, fall back to the 2 s poll.
- `CoreAudioEngine.swift:1213` + `RouterAggregate.swift:552` — **M** — quality —
  `aggregateRecoveryRequired` fires on `limiterFailures > 0` where the counter is
  cumulative for the aggregate's lifetime; one transient `AudioUnitRender` failure forces
  a full protected teardown (audible gap + mute/unmute). Fix: compare per-sample delta,
  require two consecutive samples.
- `CoreAudioEngine.swift:1061, 1071, 1175` — **L** — lag — 3 s arm + 2 s cadence + 3 stale
  samples = ≥6 s silence before aggregate recovery, ≥9 s for a stalled tap. Fix: 1 s
  cadence once `healthyStreak ≥ 5`.
- `RouterAggregate.swift:507-512` + `CoreAudioEngine.swift:1450` — **L** — meters are
  per-callback block RMS (~10 ms) sampled at 30 Hz → aliased, jumpy; three `log10` per
  tap per callback on the RT thread. Fix: publish linear sumSq + frame count atomically,
  do dB + ballistics on the actor.
- `CoreAudioEngine.swift:466-475` — **L** — `deviceMuted` returns `false` on read failure
  (`CA.uint32` defaults 0). Return `Bool?`.
- `RouterAggregate.swift:474-478` + `RouterInputMixer.swift:94-100` — **L** — memset then
  `vDSP_vsma` for every contributor; write first contributor with `vDSP_vsmul`.
- `CoreAudioEngine.swift:1084-1094` — **L** — tapIDs captured for detached format read
  while actor may destroy those taps (membership path `:883-903` does not cancel
  `routerHealthTask` before `closeRouter`; other paths do). Wasted HAL work, guarded by
  generation.
- `RouterAggregate.swift:525-541` — **L** — fade-in does `i / ch` per sample; bounded to
  2048 frames.

### 3.2 Load-analysis doc status (`docs/diagnostics/2026-09-11-coreaudio-load-analysis.md`)

Rec 1 partial (running-first reads only for playing indicator, no shared snapshot).
Rec 2 not implemented. Rec 3 partial (newest-only buffering, no debounce, full preflight
per event). Startup timing split partial via signposts; first-valid-callback time not
recorded.

### 3.3 Dead code / duplication

- `ProcessEnumerator.swift:134-144` `resolve(bundleIDs:)` no callers (only user of
  `includeDeviceIDs` / `AudioProcessInfo.deviceIDs`).
- `RMSMeter.swift:31-39` `combine` test-only; `DSPKernels.swift:21-28, 40-45, 55-60`
  scalar reference kernels test-only → move to test target.
- `RouterAggregate.swift:302, 575` `dInCh0` only logged; `Tap.inputBlocks` and
  `SourceHealthSnapshot.meter` produced, never read by policy.
- `CoreAudioEngine.swift:271-273` `tapCaptureOutputUID(defaultOutputUID:)` identity fn
  kept for one test.
- Hardware dest UID extracted three times (`:682-684`, `:748-750`, `:827-829`);
  `RouterStatus(failedMixIDs:…, cause: .buildFailed)` 12× in `startRouter`;
  `effectiveSourceGain` (`:1272-1283`) re-implements the fold in `applyRouterGains`
  (`:1425-1441`) without pan → two "is audible" definitions can diverge;
  `outputChannelCount` (`:604-614`) duplicates `RouterAggregate.outputLayout`
  (`:172-194`); `resolveOutputUID(stored:)` runs twice per `startRouter`.
- Comments: "ponytail:" tags at `CoreAudioProperty.swift:22, :108`,
  `NativePeakLimiter.swift:124`; multi-line reviewer-talk at `CoreAudioEngine.swift:954,
  978, 1041, 1099, 1503` and `RouterAggregate.swift:243, 384`.

## 4. App (`App/`)

- `ConsoleTheme.swift:213-218` + `ChannelStrip.swift:303-305, 34-36` — **H** — lag —
  `Fader` writes only the local `@State` during drag; `onCommit` fires on `onEnded`.
  Router gain and hardware volume don't move until mouse-up. Fix: add
  `onChange: (Double) -> Void`, call from `onChanged` (throttle ~30 Hz), route to
  `updateRouterGains` / `outputTargets()` without persisting; keep `onCommit` for persist.
  *(verified)*
- `ConsoleViewModel.swift:483-495` + `ConfigStore.swift:26` — **H** — perf —
  `apply()` validates twice, YAML-encodes and atomically writes `bam.yaml` synchronously
  on the main actor per call, including each Stream Deck `nudgePos` tick. Fix: debounce
  `persist` ~250-500 ms latest-wins on one `Task`; flush in `stop()` /
  `dimOutputForExit`. *(verified)*
- `ConsoleViewModel+Volume.swift:278-310` + `ConsoleViewModel.swift:172-176` — **H** —
  correctness — `dimOutputForExit` mutes, waits 1.0 s on a `DispatchSemaphore` for a
  detached teardown, exits regardless, never unmutes on timeout (by design). Reviewer
  chain: next launch `captureStockVolume` → `rememberOutputState` records the muted state
  as stock/calibration; `protectOutputs` seeds `mutes` all true; `rebuildProtectedRouter`
  (`:142/:170`) sees `muted == true` and skips the unmute. One slow quit (Bluetooth /
  aggregate teardown >1 s) leaves the device muted across launches. Fix:
  `applicationShouldTerminate` → `.terminateLater`, longer bounded teardown,
  `reply(toApplicationShouldTerminate:)`; write an exit-muted flag before the mute and
  treat an all-muted capture as unmuted calibration when set. *(semaphore verified;
  next-launch chain reviewer)*
- `ChannelStrip.swift:294-356` — **H** — UI perf — `DeviceStrip.body` reads
  `model.mixLevel(mix.id)` which depends on `snapshot` (replaced at 30 Hz). Whole strip
  incl. `header` → `deviceApps` (allocates `[SourceApp]`, filters, walks sources) and
  `AppStack` re-evaluate 30×/s per strip. `SourceApp` not `Equatable`
  (`ConsoleViewModel.swift:614`) so `AppIcon` / `Image(nsImage:)` can't be skipped. Same
  for `MasterStrip` via `masterMeter`. Fix: leaf `StripMeters(model:, mixID:)`; make
  `SourceApp: Equatable`.
- `ConsoleTheme.swift:158-172` — **M** — UI perf — `Meter.cells` builds ~40 cells and
  calls `Color(hex:)` (string parse) 3× per cell per body eval; two meters per strip at
  30 Hz. Fix: `static let` colors, precompute per-index array per `segs`. *(verified)*
- `ChannelStrip.swift:301-302, 32-33` — **M** — both meters per strip render the same
  mono level while `levelLeft/levelRight` and `masterMeterLeft/Right` exist. Feed L/R or
  render one meter.
- `ConsoleViewModel.swift:250-253, 357` — **M** — 2 s poll assigns `runningApps`,
  `outputDevices`, `playing` unconditionally; `@Observable` fires every set; same for
  `snapshot = s` while silent. Compare-before-assign (`RouterSnapshot` is Equatable).
- `ConsoleViewModel.swift:42-48` — **M** — `driverEnabled.didSet` spawns an unstructured
  `Task { reloadRouter() }` per toggle, no cancellation/serialization. *(reviewer,
  off-then-on race unverified)*. Fix: `reloadTask` cancel-and-replace via
  `enqueueRouterWork`.
- `ConsoleViewModel+Volume.swift:130-180, 226-243, 319-334` — **M** — quality — three
  copies of protect → stop/start → restore volume → restore mute → acknowledge
  (`rebuildProtectedRouter`, `stopProtectedRouter`, `restoreOutputsForExit`);
  generation/isCancelled guard repeated 3×; eight mutable state members for one concern.
  Fix: `@MainActor OutputProtection` class with one `restore(uids:fadeIn:)`.
- `CoreAudioEngine.swift:1449` — **L** (cross-cutting) — meter sampler awaits
  `routerSnapshot()` on the engine actor every 33 ms; any HAL call on the actor freezes
  meters. Fix: nonisolated meter read path (atomics already exist).
- `ConsoleViewModel+Volume.swift:267-276` — **L** — `refreshOutputVolume` ignores
  `pendingOutputTargets`; poll reads old hardware value and snaps the master fader back
  until the queued write lands.
- `ConsoleViewModel+Volume.swift:285-294` — **L** — `VolumePolicy.exit`'s `thenStock`
  discarded; `stockVolumeKey` written every launch, never used effectively.
- `ConsoleView.swift:7` — **L** — `Theme.make(dark:)` parses ~20 hex colors per body
  eval; `dark` never toggled → `static let`.
- `ConsoleViewModel+Volume.swift:412, 363, 458` — **L** — `.notice` (persisted) log per
  volume tick → `.debug`.
- `ConsoleViewModel.swift:135` — **L** — `persist(config)` every launch even when
  `normalize` changed nothing.
- `ConsoleTheme.swift:443-447` `Pill` erases to `AnyView`; `ChannelStrip.swift:610`
  `ForEach(id: \.offset)` re-identifies on reorder; `ConsoleViewModel.swift:536`
  `routerMutationTask!` force unwrap.
- Magic numbers to name: 83 ms push, 2 s poll, 24×50 ms ramp, 1.0 s exit timeout, 30 s
  backoff cap, 38 pt bar.
- Lifecycle *(unverified)*: no `NSWorkspace.didWakeNotification`; a Bluetooth output
  reconnecting under the same UID without a device-list change triggers no rebuild.

Dead code (zero callers in App, AppTests, BamControlKit): `App/MeterBar.swift` (whole
file); `ConsoleTheme.swift` `Knob` 241-296, `Tag` 461-472, `BamMark` 475-495, `consoleDb`
123-128, `Console.destLabel` 113-120, `Theme.soft` 14, `Meter.horizontal` 140;
`ConsoleViewModel+Routing.swift` `sourceLevel` 7, `selectMix/addMix/deleteMix/renameMix`
25-45, `isRouted/setRouted` 53-75, `addSource(app:)/deleteSource` 100-121,
`assignApp(_:to:)` 135-145, `soloID/toggleSolo/pan/setPan` 291-297;
`ConsoleViewModel.swift` `activeMix` 116-119, `openGroupID` 37, `dark` 36, `mixes/sources`
113-114; `ConsoleViewModel+Volume.swift:346-360` `restoreOutputVolume` test-only.

## 5. BamCore / BamControlKit / build

- `ControlServer.swift:100` — **H** — liveness — accepted fds blocking; `sendFrame`
  loops on `Darwin.send` on serial `bgQueue`. A client that stops reading blocks the next
  30 fps meter write forever → accept, all clients, command dispatch and
  `diagnosticsSnapshot()` (`bgQueue.sync` from main actor) all stall. Fix: `O_NONBLOCK`
  or `SO_SNDTIMEO`, `EAGAIN` = drop frame, evict after N drops. *(verified)*
- `ControlServer.swift:225, 381` — **H** — local IPC — socket 0600, no peer check beyond
  hello. Any same-user process can `setMasterPos pos=1.0` → hardware 100%. Same-uid trust
  is macOS norm, but Makefile documents a stuck-high level has hurt before. Fix: cap /
  rate-limit control-originated master writes; optionally `LOCAL_PEERCRED` +
  `SecCodeCopyGuestWithAttributes` Team ID check.
- `ControlServer.swift:412` — **M** — each `cmd` spawns an independent
  `Task { @MainActor }`; two rapid `setPos` can apply out of order. Fix: one
  `AsyncStream` consumed by a single MainActor task.
- `ControlServer.swift:528-546` — **M** — protocol — diff emits `removed`/`delta` but
  never an event for a newly added mix; client learns only on re-handshake.
- `ControlServer.swift:442, 459, 473` — **M** — fd reuse — `listMixes`, `listOutputs`,
  `setOutputDevice` reply to captured `Client` after actor hop without the
  `clients.contains` guard used at `:373`.
- `ControlServer.swift:315` — **M** — `readBuffer` unbounded for a client that never sends
  newline. Cap 64 KiB.
- `ControlServer.swift:287` — **M** — no client cap, no handshake timeout. Cap 16, drop
  un-handshaked after 5 s.
- `ControlServer.swift:497-499, 564` — **M** — timer 30 fps, app pushes every 83 ms
  (`ConsoleViewModel.swift:162`) → ~60% of ticks re-send identical frames;
  `JSONSerialization` once per client. Skip when `snap == lastSnapshot`; encode once.
  *(verified)*
- `BamConfig.swift:56` — **M** — validation — `master`, `Mix.level`, `Send.level`, `pans`
  never range-checked; `level: 5` or `.nan` reaches
  `config.master * mix.level * send.level` unclamped (`CoreAudioEngine.swift:1434`).
- `ConsoleViewModel.swift:136-140` — **M** — on corrupt config the app uses seed but
  leaves `configURL` nil → `persist()` silently no-ops all session. Rename bad file,
  set URL, banner.
- `ControlServer.swift:9` — **M** — `kBuildVersion = "1.0.7"` hard-coded; `make release`
  doesn't touch it. Read `CFBundleShortVersionString`.
- `project.yml:72-81` — **M** — `bamTests` is a logic-test bundle linking
  `bam dev.debug.dylib`; the `-fmodule-map-file` + `$(PROJECT_TEMP_DIR)/../../../`
  walk exists because `@testable import bam` needs CYaml/_AtomicsShims module maps. Fix:
  declare BamKit products as `bamTests` dependencies; if double-link warnings, switch to
  `TEST_HOST` app-hosted tests.
- **L**: `send` returns true when `encodeFrame` throws (`:87`); `stopListening` never
  unlinks socket (`:267-276`); `sun_path` truncation unguarded (`:229-234`); socket dir
  `me.harke.bam/` vs config dir `bam/` (`:201` vs `ConfigStore.swift:13`);
  `MockMixerControl.swift:111` drops icon; `RouterRecovery.swift:31-41` cooldown < window
  edge; `RMSMeter.swift:41` `minDB: 0` → NaN; `MeterSnapshot.swift:5, 22` two identical
  structs; `scripts/install.sh` duplicates `make install` minus SAFE_VOLUME/pkill;
  `install-streamdeck-plugin.sh:128` `ditto` merges (stale files survive) → `rm -rf` first;
  CI actions pinned by tag not SHA, `brew install xcodegen` unpinned; `renovate.json`
  schema-only (add `config:recommended`); `leankg.yaml` targets go/ts/py only → delete;
  `(Q11)/(Q12)/(Q14)/(Q20)` comments reference a Q&A not in repo.
- Deps: Yams 6.2.2 / swift-atomics 1.3.1 current. `Synchronization.Atomic` needs macOS 15;
  target is 14.4 so swift-atomics stays.

## 6. Stream Deck (`BamKit/Sources/BAMStreamDeck`, `StreamDeck/`)

- `ActionRouter.swift:283` + `KeyStyleImage.swift:78` — **H** — lag — retro key style
  quantizes to 100 steps and takes the CGContext → PNG → base64 path; nearly every meter
  frame = fresh ~15-30 KB PNG + `setImage` per retro key. Channel/meter keys (12/18 steps,
  SVG) are fine. Fix: ~24 steps + per-context throttle (~10-12 fps), or SVG with cached
  dial texture and live needle only. *(verified)*
- `manifest.json:19` — **H** — `MinimumVersion: "12"` vs `.macOS("14.4")`. Set 14.4.
  *(verified)*
- `ActionRouter.swift:85, :500, :662` — **M** — `dialFeedbackInterval = 1/40 s` but
  server ticks every 33 ms → throttle never engages; 4 dials = 120 WS msgs/s. Raise to
  1/15-1/20 s. Test `ActionRouterMessageTests.swift:103` uses real `Task.sleep` (flaky).
- `ActionRouter.swift:914-919` — **M** — `dialFeedbackSignature` includes 100-step
  `levelPercent` not rendered by any layer → phantom `setFeedback` with only undeclared
  keys (`title/value/slider/meter`), discarded by Stream Deck.
- `ActionRouter.swift:152`, `UDSClient.swift:130-136` — **M** — `applicationDidLaunch` /
  `applicationDidTerminate` ignored; no disconnect callback; after BAM restart keys show
  stale state up to 10 s. Fix: reset backoff + connect on launch; `markOffline()` on
  terminate/disconnect.
- `ActionRouter.swift:14, :304, :635-654` — **M** — `.deviceDial`/`.masterDial` map to
  action UUIDs the manifest no longer declares; verbatim copies of encoder branches.
  Delete (~50 lines).
- `ActionRouter.swift:91-113, :132-146, :164-174` — **M** — eleven parallel per-context
  dictionaries hand-cleared in two places. Fix: `RenderCache` struct on `Binding`.
- `RetroMeterDrawing.swift` — **M** — ~150 dead lines: `renderLCD` (test-only),
  `drawStereoMeters`, `drawVerticalMeter`, `drawRetroReadout`, `drawReadout`, `drawTicks`,
  `angle(for:)`, circular `drawNeedle`/`point`, `shortName`, non-compact `drawFace`.
- `KeyStyleImage.swift:37-64, 396-407, 471-490, 520-546` — **M** — PNG drawers for
  channel/meter exist only for tests; each has an SVG twin. Delete, make `render`
  retro-only.
- `KeyImage.swift:44`, `KeyStyleImage.swift:134`, `RetroMeterDrawing.swift:491` — **M** —
  three `drawGlyph` copies, three text helpers, three muted reds. One `GlyphDrawing` +
  shared palette.
- **L**: manifest lacks `DisableAutomaticStates: true` on two-state actions;
  `refreshOutput` unguarded re-render + N² `listOutputs` at startup (`:702-721`, `:179`);
  adjust wrap uses `?? 0` (`:320`) where master branch deliberately avoids it;
  `peakWindows` copy-on-write per frame (`:488-491`); `setFeedbackLayout` re-sent on every
  `didReceiveSettings` (`:175-178`); `launchAttempted` never resets (`UDSClient.swift:139`);
  WS receive failure leaves process lingering (`ElgatoConnection.swift:109`); `touchTap` /
  `dialUp` ignored (`:148`); `common.js:27` requests mixes for every PI, persists a setting
  as render side effect; ~50 lines duplicated `device.html` vs `master.html`; PI never
  handles `didReceiveSettings`; 14 unreferenced icon files; stale "Phase 2/5" comments.

## 7. BAMDriver — dead, delete

Evidence: `55d9bcb` (2026-06-06) deleted `BAMSlotClaim.swift` and
`VirtualDeviceClient.swift`, the only Swift clients, and is the last commit touching
`BAMDriver.c`. Zero hits in `App/` or `BamKit/Sources` for `bmcf`/`bmcl`/`bmnm`/`bmch`,
`me.harke.bam.driver`, or `kAudioObjectPropertyCustomPropertyInfoList`. The only
`BAM_UID_` reference (`ConsoleViewModel+Volume.swift:259`) *hides* such devices. Not
referenced by Makefile, project.yml, CI, scripts, or cask. `driverEnabled` toggles the
process-tap router, not the plug-in.

If ever revived, mandatory first: `BAMDriver.c:836` ticks-per-frame only for slot 0
(**C**, clock broken for slots 1-7); `:2481` unlocked read+retain of `gBAM_MixName` vs
locked release (**H**, coreaudiod crash); `:1969` BoxUID getter never writes
`*outDataSize` (**H**); `:2683` NominalSampleRate returns slot 0 for every device
(**H**); `:1439, 1483` inverted qualifier-size guard (**M**); `:4136` one global mutex in
`GetZeroTimeStamp` for all eight devices (**M**); plus dead pitch/clock subsystem,
BlackHole identity strings, `install.sh` `killall coreaudiod`.

Cleanup with the delete: `README.md:98, 105-109`; `.wolf/anatomy.md:126-138, 149`;
`.wolf/cerebrum.md:65`; later `MixDestination.virtualSlot` (`Mix.swift:29`), "BAM \(s)"
label (`ConsoleTheme.swift:116`), `BAM_UID_` filter. Removes the GPL-3 subtree from an
MIT repo.

## 8. Test coverage gaps (union)

- No test: capture-rate ≠ output-rate or split-device drift; RT-safety harness (mixer +
  limiter under malloc/lock trap); `ChangeListener` registration failure;
  `routerSnapshots` re-subscription cancels prior sampler; fake-clock health-monitor
  timing; `deviceMuted` read-failure; limiter `delayFrames` upper bound.
- No test: fader drag → engine; meter delivery / re-render cost; exit timeout →
  next-launch muted; rapid `driverEnabled` toggling; persistence frequency;
  poll-vs-queued-write fader snap-back; no view-layer tests at all.
- No test: slow/non-reading control client; add-mix diff; un-handshaked accumulation;
  oversized line; fd reuse; out-of-order `setPos`; out-of-range/NaN config; corrupt-file
  recovery; `AudioTaper` monotonicity/round-trip; `RouterRecoveryPolicy` cooldown < window.
- No test: Stream Deck `willDisappear` cleanup; retro key re-render rate; reconnect /
  state-after-hello; PI JavaScript; glyph selection fallback. Dial 30 fps test uses
  wall-clock sleeps.

## 9. Suggested sequencing

1. **Day 1, low risk:** manifest min OS; fader `onChange`; debounce persist;
   `ControlServer` non-blocking + caps; compare-before-assign; hoist colors; retro key
   throttle; `.notice` → `.debug`.
2. **Week 1, medium:** hardware executor off the engine actor; off-actor router build
   with generation commit; `OutputProtection` extraction; exit `.terminateLater`.
3. **Measure before changing:** split-device clock drift (§3.1); limiter latency.
4. **Cleanup PRs:** delete BAMDriver + dead Swift; dedupe Stream Deck drawing; move
   scalar kernels to tests; comment trim per one-line rule.
