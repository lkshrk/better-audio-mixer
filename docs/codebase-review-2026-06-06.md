# BAM Codebase Review - 2026-06-06

Scope: full repository review of the SwiftUI app, BamKit libraries, Stream Deck plugin, local control socket, CoreAudio routing engine, build/test setup, and driver surface.

Validation run:

- `make test`
- Result: failed in `BamKit` before the Xcode app test phase.
- Concrete failure: `ControlServerTests.testDeadClientPrunedOnEPIPE` timed out waiting for a second client handshake after a dead client was closed.
- Other package tests shown before failure: 58 executed package tests passed, 2 live router smoke tests skipped.

Note: the worktree already had uncommitted router recovery changes before this review. `make test` also regenerated `bam.xcodeproj` through XcodeGen as part of the Makefile target.

## Executive Summary

The strongest parts of the codebase are the domain split and the testable core: `BamCore` owns routing/config/policies, `AudioEngine` owns CoreAudio specifics, `BamControlKit` owns the local socket protocol, and the app uses a protocol-backed view model with mock coverage. The recent router recovery direction is conceptually good: it moves recovery from blind polling to cause-aware event handling and adds policy tests.

The highest-risk issues are lifecycle/resource ownership bugs around long-lived listeners and sockets, plus a failing control-server test that matches a real descriptor-ownership smell. The biggest refactoring opportunity is to split `ConsoleViewModel` into smaller modules around app/device discovery, router lifecycle/recovery, device volume safety, and config mutation. That would improve locality without weakening the existing test surface.

## Findings

### High - Router event listeners leak and multiply after resubscribe

Files:

- `BamKit/Sources/AudioEngine/CoreAudioEngine.swift:573`
- `BamKit/Sources/AudioEngine/CoreAudioEngine.swift:580`
- `BamKit/Sources/AudioEngine/CoreAudioEngine.swift:598`
- `App/ConsoleViewModel.swift:363`

`CoreAudioEngine.routerEvents()` creates three `ChangeListener`s for every stream subscription and appends them to `routerEventListeners`. There is no `onTermination` cleanup path for that stream. `ConsoleViewModel.subscribeRouterEvents()` cancels and recreates the stream when the router is reloaded or driver toggled, so each reload can leave old CoreAudio property listeners alive.

Impact:

- Duplicate CoreAudio events and redundant `startRouterReconciling()` calls over time.
- Memory/resource leak for `ChangeListener` instances.
- Old `AsyncStream` continuations stay reachable through listener closures, even after the consuming task was cancelled.
- The bug is more likely after repeated driver toggles, output switches, or router recovery loops.

Recommended fix:

- Store listener groups per stream id and remove them in `AsyncStream.onTermination`.
- Or make `routerEvents()` a single shared stream/listener set inside the actor, with explicit fanout to active subscribers.
- Add a regression test using `MockAudioEngine`-style hooks or an injectable listener factory that verifies repeated subscribe/cancel leaves one active listener group.

### High - Control socket descriptor ownership is split and current tests fail

Files:

- `BamKit/Sources/BamControlKit/ControlServer.swift:205`
- `BamKit/Sources/BamControlKit/ControlServer.swift:210`
- `BamKit/Sources/BamControlKit/ControlServer.swift:211`
- `BamKit/Sources/BamControlKit/ControlServer.swift:227`
- `BamKit/Sources/BamControlKit/ControlServer.swift:251`

`ControlServer.stopListening()` closes every `Client` directly, then cancels every read source whose cancel handler also closes the same descriptor. Normal `removeClient()` relies on the read-source cancel handler for close, while the fallback path closes directly. That creates mixed fd ownership, and fd reuse makes this class of bug dangerous.

Validation evidence:

- `make test` failed at `ControlServerTests.testDeadClientPrunedOnEPIPE`.
- Failure: timeout after 3.0s when establishing/reading the follow-up "alive" client handshake after closing the first client.

Impact:

- Tests are currently red.
- Server can become unable to serve the next client after a dead-client path.
- Double-close can close a newly reused descriptor under load or during shutdown.

Recommended fix:

- Give exactly one object responsibility for closing each fd.
- Prefer `DispatchSource` cancel handlers for source-owned fds and remove direct `Client.close()` calls for clients with active sources.
- In `stopListening()`, cancel read sources first, clear source maps, and let cancel handlers close. Only directly close clients that have no source.
- Add assertions or wrapper types around fd ownership so future code cannot close through two paths.

### Medium - Permission heartbeat bypasses the central router-status fold

Files:

- `App/ConsoleViewModel.swift:342`
- `App/ConsoleViewModel.swift:350`
- `App/ConsoleViewModel.swift:351`
- `App/ConsoleViewModel.swift:352`
- `App/ConsoleViewModel.swift:353`

`scheduleRouterRecovery()` calls `engine.startRouter(config:)` and then assigns `routerStatus` / `failedMixIDs` directly. Every other router start goes through `applyRouterStatus()`, which also updates `audioRecoveryDisplayState` and schedules the next recovery policy. The heartbeat path intentionally returns when the cause changes, but it does not fold `.ok` or the new cause through the same logic.

Impact:

- Status state can diverge by path.
- Recovery display can remain stale until a separate router recovery event arrives.
- Future changes to `applyRouterStatus()` will not automatically apply to heartbeat recovery.

Recommended fix:

- Replace the direct assignments with `applyRouterStatus(next)`.
- Add a regression test for permission heartbeat changing to `.noOutput` and for `.ok`, verifying both `routerStatus` and `audioRecoveryDisplayState`.

### Medium - Detached router-start tasks can race topology changes

Files:

- `App/ConsoleViewModel.swift:1022`
- `App/ConsoleViewModel.swift:1030`
- `App/ConsoleViewModel.swift:1034`
- `App/ConsoleViewModel.swift:1036`

`apply(topology:)` persists a new config and launches an unstructured `Task` to either rebuild the router or update gains. Rapid UI changes can enqueue multiple engine operations whose completion order is not tied to the latest `config`. Since a topology rebuild can finish after a later gain-only update, an older draft can be applied last.

Impact:

- Stale router state after fast edits.
- Extra aggregate rebuilds.
- Hard-to-reproduce audio state because the UI state is current while the engine may have applied an older draft.

Recommended fix:

- Introduce a single router command task/actor in the view model that serializes engine mutations and coalesces drafts.
- Track a monotonically increasing generation; discard results not matching the latest generation before calling `applyRouterStatus()`.
- Keep `setSystemOutput()` as the explicit awaited path, but route ordinary topology/gain changes through the same queue.

### Medium - Palette fallback colors are not actually stable across launches

File:

- `App/ConsoleTheme.swift:102`

The comment promises stable identity colors, but `String.hashValue` is intentionally randomized per process in Swift. Any device/source without an explicit hue can change color across app launches. The Stream Deck code already uses stable FNV-1a hashing for this exact problem.

Impact:

- Device identity colors can drift between launches.
- Screenshots and Stream Deck/app visuals can disagree.

Recommended fix:

- Replace `abs(id.hashValue)` with a deterministic hash, preferably sharing the FNV-1a helper already used by `ActionRouter.accent(forID:)`.
- Add a tiny test that fixed ids map to fixed hue buckets.

### Medium - Missing app icons are not negatively cached

Files:

- `App/ConsoleTheme.swift:347`
- `App/ConsoleTheme.swift:348`
- `App/ConsoleTheme.swift:350`
- `App/ConsoleTheme.swift:351`
- `App/ConsoleTheme.swift:353`

`AppIconCache` is declared as `[String: NSImage?]`, but assigning `nil` through a dictionary subscript removes the key. For bundle IDs that cannot be resolved, `cache[bundleID] = img` does not cache the miss. SwiftUI body recomputation can repeatedly call `NSWorkspace.shared.urlForApplication` for unresolved apps.

Impact:

- Avoidable main-actor work during app picker/list rendering.
- Worse when helper apps or recently removed apps are present.

Recommended fix:

- Use an enum cache value such as `.found(NSImage)` / `.missing`, or store `[String: NSImage]` plus a separate `missing` set.
- Add a small testable resolver wrapper so cache behavior can be verified without hitting `NSWorkspace`.

### Medium - `ConsoleViewModel` has too many responsibilities

File:

- `App/ConsoleViewModel.swift` - 1124 lines

This module handles config load/normalize/persist, app/device polling, router start/recovery subscriptions, output-volume safety, Stream Deck control snapshots, device CRUD, app assignment, fader/gain mutation, and UI display derivations.

Impact:

- The most safety-critical logic, output dim/restore and router recovery, is interleaved with routine UI mutations.
- Tests must instantiate a broad object even when they only care about one policy.
- New behavior tends to be added as another task/property on the same object.

Recommended refactor:

- Extract `RouterLifecycleController` for start/reload/recovery/event subscriptions.
- Extract `OutputVolumeCoordinator` for launch/exit/switch safety, backed by `VolumePolicy`.
- Extract `ConfigEditor` or pure mutation helpers for device/app assignment and topology vs gain classification.
- Keep `ConsoleViewModel` as a MainActor composition root and UI projection layer.

### Medium - Stream Deck action router is a deep but overloaded module

File:

- `BamKit/Sources/BAMStreamDeck/ActionRouter.swift` - 565 lines

`ActionRouter` handles Elgato event binding, BAM wire-frame ingestion, output switching, PI list forwarding, key rendering, dial rendering, metering ballistics, global settings cache, and optimistic state transitions.

Impact:

- The module has good internal locality, but unrelated change types collide in one file.
- Output switching and visual rendering are harder to test independently.

Recommended refactor:

- Extract pure reducers for `ingestState` / `ingestDelta` / `ingestOutputs`.
- Extract `DeckVisualPresenter` for `refresh`, key image selection, dial feedback, and throttling.
- Keep `ActionRouter` as event dispatcher and state owner.

### Low - `ChannelStrip.swift` mixes many independent SwiftUI controls

File:

- `App/ChannelStrip.swift` - 758 lines

The file contains master strip, output list, recovery popover, device strip, edit sheet, icon/color pickers, app stack, app picker, emoji capture, and AppKit bridge code.

Impact:

- UI changes are harder to review.
- Preview/test targeting individual controls is harder.
- This contributes to broad SwiftUI invalidation because many views share direct `@Bindable model` access.

Recommended refactor:

- Split by control family: `MasterStrip`, `DeviceStrip`, `DeviceEditSheet`, `AppPicker`, `EmojiCatcher`.
- Pass narrow values/actions to low-level views where practical rather than the whole model.

### Low - C driver is too large for normal review feedback loops

File:

- `BAMDriver/BAMDriver.c` - 4334 lines

The driver is a derivative of BlackHole and likely intentionally monolithic, but at this size it is hard to review local BAM-specific changes safely.

Impact:

- Driver changes have a high blast radius.
- It is difficult to distinguish vendor-derived code from BAM-specific deltas.

Recommended improvement:

- Preserve upstream/vendor sections explicitly and isolate BAM-specific changes in clearly marked blocks or companion files where possible.
- Add a driver-focused smoke checklist and keep it separate from the app-level routing tests.

## Performance Notes

- The audio IO path in `RouterAggregate` is appropriately written with preallocated scratch buffers, primitive loops, atomics, no allocation in the IOProc, and no actor hops. This is one of the strongest parts of the codebase.
- `ActionRouter` throttles full PNG key refreshes to about 10fps and sends smaller dial feedback every meter frame. That is a good performance tradeoff.
- The app UI still observes a broad `@Observable ConsoleViewModel`. Meter updates at ~30fps update `snapshot`, which can invalidate more view tree than necessary. If UI jank appears, split meter state into a narrower observable model or pass per-strip meter values through small value projections.
- `ControlServer` pushes snapshots at ~12fps regardless of whether clients need full visual updates; the diffing helps, but JSON encoding still happens on the background queue every tick. This is acceptable now, but if Stream Deck traffic grows, pre-encode stable frames or skip meter frames when all levels are floor/silent.

## Test Coverage Gaps

- No test proves `routerEvents()` subscription cleanup.
- No test exercises repeated driver toggle / reload and verifies only one event recovery path remains active.
- The failing `testDeadClientPrunedOnEPIPE` should be kept and fixed, not deleted.
- `Palette.hue(for:)` needs deterministic hashing coverage.
- `AppIconCache` needs a resolver abstraction to test negative-cache behavior.
- Live router smoke tests are skipped by default, which is reasonable, but release readiness should include a manual or CI-gated `BAM_SMOKE=1` pass on supported hardware.

## Prioritized Improvement Plan

1. Fix `ControlServer` fd ownership and get `make test` green.
2. Fix `CoreAudioEngine.routerEvents()` cleanup and add repeated subscribe/cancel coverage.
3. Route permission heartbeat results through `applyRouterStatus()`.
4. Add generation/coalescing for router rebuild/update tasks in `ConsoleViewModel`.
5. Replace unstable `Palette.hue` hashing and fix app-icon negative caching.
6. Extract `OutputVolumeCoordinator` and `RouterLifecycleController` from `ConsoleViewModel`.
7. Split `ChannelStrip.swift` and `ActionRouter.swift` after behavior is locked by tests.

