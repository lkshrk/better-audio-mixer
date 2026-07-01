# Engine Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close a routing correctness hole, make router-recovery throttling per-reason, remove the output-switch volume blast, and speed the RT IOProc with a transparent vDSP + lookahead-limiter path — without regressing audio.

**Architecture:** Pure logic (config validation, recovery policy, DSP kernels, limiter) lives in `BamCore`/`AudioEngine` as testable value types/functions with scalar reference implementations. The `CoreAudioEngine` actor and `RouterAggregate` IOProc call those tested pieces. Every risky RT change is guarded by offline golden-buffer tests at epsilon `1e-6`.

**Tech Stack:** Swift 6.0, CoreAudio, Accelerate/vDSP, swift-atomics, Swift Testing (BamCore tests) + XCTest (AudioEngine tests).

## Global Constraints

- **Swift 6.0**, strict concurrency; macOS 14.4 deployment floor.
- **No allocation, no locks, no Swift generic/tuple/`Range` metadata on the audio thread** — the IOProc block and anything it calls take raw pointers + counts only (preserves the metadata-lock deadlock fix documented in `RouterAggregate.startIO`, `RouterAggregate.swift:223-234`). All scratch is preallocated in `startIO`.
- **Audio transparency is an acceptance gate:** golden-buffer tests assert `|vDSP − scalar| < 1e-6` on output samples and every meter value; bit-exact passthrough when the summed peak ≤ full-scale.
- **Match surrounding test framework:** new BamCore tests use Swift Testing (`import Testing`, `@Test`, `#expect`) like `RMSMeterTests`/`BamConfigTests`; new AudioEngine tests use XCTest like `MixerTests`/`InterleaveTests`.
- **No new code comments** except a one-line WHY where a constraint is non-obvious (repo convention).
- Existing static device helpers on `CoreAudioEngine` are reused verbatim — do not re-implement: `Self.setDeviceMuted(uid:_:)`, `Self.deviceVolume(uid:)`, `Self.setDeviceVolume(uid:_:)` (call sites at `CoreAudioEngine.swift:586-596`).
- Branch: `engine-improvements` (already checked out). Commit after every task.

---

## File Structure

**Create:**
- `BamKit/Sources/AudioEngine/DSPKernels.swift` — pure sum/RMS/peak/fade kernels (scalar reference + vDSP), raw-pointer signatures.
- `BamKit/Tests/AudioEngineTests/DSPKernelTests.swift` — golden-buffer equivalence tests.

**Modify:**
- `BamKit/Sources/BamCore/BamConfig.swift` — `BamConfigError` + `validateRouting` guardrail (A1).
- `BamKit/Sources/BamCore/RouterRecovery.swift` — `RecoveryReason` enum, per-reason budgets, `pausedUntil(for:)` accessor (A2/A3).
- `BamKit/Sources/AudioEngine/CoreAudioEngine.swift` — reason enum wiring, re-arm timer, `healthyStreak` auto-reset, `performGuardedOutputRebuild`, guarded `startRouter`, log wording (A2/A3/A4/A6/A7).
- `BamKit/Sources/AudioEngine/AudioLimiter.swift` — lookahead envelope limiter (G).
- `BamKit/Sources/AudioEngine/RouterAggregate.swift` — IOProc calls kernels + limiter; preallocate lookahead buffer (A5/G).
- `BamKit/Tests/BamCoreTests/RouterRecoveryPolicyTests.swift` — per-reason + pausedUntil tests (A2/A3).
- `BamKit/Tests/BamCoreTests/BamConfigTests.swift` (or `RoutingModelTests.swift`) — guardrail test (A1).
- `BamKit/Tests/AudioEngineTests/` — limiter tests (G).

**Test command (all BamKit):**
```bash
cd BamKit && swift test
```
**Single test:** `cd BamKit && swift test --filter <TestName>`

---

## Task 1 (A6): Fix misleading recovery log wording

**Files:**
- Modify: `BamKit/Sources/AudioEngine/CoreAudioEngine.swift` (log strings in `checkRouterHealth`, ~`:480,:502`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (cosmetic).

- [ ] **Step 1: Locate the misleading strings**

Run: `cd BamKit && grep -n "rebuilding tap(s)" Sources/AudioEngine/CoreAudioEngine.swift`
Expected: two hits (tap format drift, source tap stalled).

- [ ] **Step 2: Edit the two log lines**

In `checkRouterHealth`, change both messages so they say the aggregate is rebuilt (the recovery path calls full `startRouter`, not a per-tap rebuild). Example — the tap-format-drift line:

```swift
bamLog("router health failed: tap format changed for \(formatBad.sorted().joined(separator: ",")); dropping tap cache and rebuilding aggregate", level: .error)
```

And the source-stalled line:

```swift
bamLog("router health failed: source tap stopped advancing for \(sourceFrameBad.sorted().joined(separator: ",")); dropping tap cache and rebuilding aggregate", level: .error)
```

- [ ] **Step 3: Build**

Run: `cd BamKit && swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add BamKit/Sources/AudioEngine/CoreAudioEngine.swift
git commit -m "fix(engine): correct recovery log wording (rebuilds aggregate, not single tap)"
```

---

## Task 2 (A1): Reject virtualSlot destinations in validation

**Files:**
- Modify: `BamKit/Sources/BamCore/BamConfig.swift` (`BamConfigError` enum + `validateRouting()`)
- Test: `BamKit/Tests/BamCoreTests/BamConfigTests.swift`

**Interfaces:**
- Consumes: `MixDestination` (`.virtualSlot(Int)` / `.hardware(uid:)`), `Mix`.
- Produces: `BamConfigError.unsupportedVirtualDestination(String)` — the mix id.

- [ ] **Step 1: Write the failing test**

Add to `BamConfigTests.swift` (Swift Testing style):

```swift
@Test func virtualSlotDestinationRejected() {
    let cfg = BamConfig(
        sources: [Source(id: "s1", name: "A", kind: .app, bundleIDs: ["com.a"])],
        mixes: [Mix(id: "m1", name: "M1", dest: .virtualSlot(0),
                    sends: [Send(source: "s1")])]
    )
    #expect(throws: BamConfigError.unsupportedVirtualDestination("m1")) {
        try cfg.validate()
    }
}

@Test func hardwareDestinationAllowed() throws {
    let cfg = BamConfig(
        sources: [Source(id: "s1", name: "A", kind: .app, bundleIDs: ["com.a"])],
        mixes: [Mix(id: "m1", name: "M1", dest: .hardware(uid: "UID"),
                    sends: [Send(source: "s1")])]
    )
    try cfg.validate()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd BamKit && swift test --filter virtualSlotDestinationRejected`
Expected: FAIL — `unsupportedVirtualDestination` not a member of `BamConfigError`.

- [ ] **Step 3: Add the error case**

In `BamConfig.swift`, add to `enum BamConfigError`:

```swift
case unsupportedVirtualDestination(String)
```

And in its `description` switch:

```swift
case .unsupportedVirtualDestination(let mix):
    return "Mix \(mix) routes to a virtual device, which is not yet supported"
```

- [ ] **Step 4: Add the validation rule**

In `validateRouting()`, after the existing remainder check (`BamConfig.swift:105-106`), append:

```swift
for mix in mixes {
    if case .virtualSlot = mix.dest {
        throw BamConfigError.unsupportedVirtualDestination(mix.id)
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd BamKit && swift test --filter BamConfigTests`
Expected: PASS (both new tests + existing).

- [ ] **Step 6: Commit**

```bash
git add BamKit/Sources/BamCore/BamConfig.swift BamKit/Tests/BamCoreTests/BamConfigTests.swift
git commit -m "feat(core): reject virtualSlot mix destinations in validation"
```

---

## Task 3 (A2): RecoveryReason enum + per-reason budgets

**Files:**
- Modify: `BamKit/Sources/BamCore/RouterRecovery.swift`
- Test: `BamKit/Tests/BamCoreTests/RouterRecoveryPolicyTests.swift`

**Interfaces:**
- Consumes: `RouterRecoveryEvent` (unchanged: `.attempting(reason:attempt:)`, `.paused(reason:attempts:window:cooldown:)`, `.recovered`).
- Produces:
  - `enum RecoveryReason: String, Sendable, Equatable, CaseIterable { case aggregateStalled, outputFormatDrift, tapFormatDrift, sourceTapStalled }`
  - `RouterRecoveryPolicy.recordAttempt(reason: RecoveryReason, now: Date = Date()) -> RouterRecoveryEvent`
  - `RouterRecoveryPolicy.pausedUntil(for: RecoveryReason) -> Date?`
  - `RouterRecoveryPolicy.reset()` clears all reasons.
  - `RouterRecoveryEvent.reason` stays `String` (event carries `reason.rawValue` for UI/Mock consumers).

- [ ] **Step 1: Write the failing tests**

Replace/extend `RouterRecoveryPolicyTests.swift`. Add (Swift Testing style — match the file's existing framework; if it is XCTest, convert accordingly):

```swift
@Test func perReasonBudgetsAreIndependent() {
    var p = RouterRecoveryPolicy(maxAttempts: 2, window: 100, cooldown: 300)
    let t0 = Date(timeIntervalSince1970: 0)

    // Exhaust one reason.
    _ = p.recordAttempt(reason: .outputFormatDrift, now: t0)
    _ = p.recordAttempt(reason: .outputFormatDrift, now: t0)
    let driftPaused = p.recordAttempt(reason: .outputFormatDrift, now: t0)
    guard case .paused = driftPaused else { Issue.record("expected paused"); return }

    // A different reason still has its full budget.
    let other = p.recordAttempt(reason: .aggregateStalled, now: t0)
    guard case .attempting(_, let attempt) = other else { Issue.record("expected attempting"); return }
    #expect(attempt == 1)
}

@Test func pausedUntilReportedPerReason() {
    var p = RouterRecoveryPolicy(maxAttempts: 1, window: 100, cooldown: 300)
    let t0 = Date(timeIntervalSince1970: 0)
    _ = p.recordAttempt(reason: .aggregateStalled, now: t0)
    let paused = p.recordAttempt(reason: .aggregateStalled, now: t0)
    guard case .paused = paused else { Issue.record("expected paused"); return }
    #expect(p.pausedUntil(for: .aggregateStalled) == t0.addingTimeInterval(300))
    #expect(p.pausedUntil(for: .outputFormatDrift) == nil)
}

@Test func resetClearsAllReasons() {
    var p = RouterRecoveryPolicy(maxAttempts: 1, window: 100, cooldown: 300)
    let t0 = Date(timeIntervalSince1970: 0)
    _ = p.recordAttempt(reason: .aggregateStalled, now: t0)
    _ = p.recordAttempt(reason: .aggregateStalled, now: t0)   // pause
    p.reset()
    let after = p.recordAttempt(reason: .aggregateStalled, now: t0)
    guard case .attempting = after else { Issue.record("expected attempting after reset"); return }
    #expect(p.pausedUntil(for: .aggregateStalled) == nil)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BamKit && swift test --filter RouterRecoveryPolicyTests`
Expected: FAIL — `RecoveryReason` undefined, `recordAttempt(reason: RecoveryReason...)` mismatch.

- [ ] **Step 3: Implement the enum + per-reason policy**

Rewrite `RouterRecovery.swift`. Keep `RouterRecoveryEvent` as-is. Replace the policy internals:

```swift
public enum RecoveryReason: String, Sendable, Equatable, CaseIterable {
    case aggregateStalled
    case outputFormatDrift
    case tapFormatDrift
    case sourceTapStalled
}

public struct RouterRecoveryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var window: TimeInterval
    public var cooldown: TimeInterval

    private var attempts: [RecoveryReason: [Date]] = [:]
    private var paused: [RecoveryReason: Date] = [:]

    public init(maxAttempts: Int = 3, window: TimeInterval = 120, cooldown: TimeInterval = 300) {
        self.maxAttempts = max(1, maxAttempts)
        self.window = window
        self.cooldown = cooldown
    }

    public mutating func recordAttempt(reason: RecoveryReason, now: Date = Date()) -> RouterRecoveryEvent {
        if let until = paused[reason], now < until {
            return .paused(reason: reason.rawValue, attempts: attempts[reason]?.count ?? 0,
                           window: window, cooldown: cooldown)
        }
        var recent = (attempts[reason] ?? []).filter { now.timeIntervalSince($0) <= window }
        guard recent.count < maxAttempts else {
            attempts[reason] = recent
            paused[reason] = now.addingTimeInterval(cooldown)
            return .paused(reason: reason.rawValue, attempts: recent.count,
                           window: window, cooldown: cooldown)
        }
        recent.append(now)
        attempts[reason] = recent
        paused[reason] = nil
        return .attempting(reason: reason.rawValue, attempt: recent.count)
    }

    public func pausedUntil(for reason: RecoveryReason) -> Date? {
        paused[reason]
    }

    public mutating func reset() {
        attempts.removeAll()
        paused.removeAll()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd BamKit && swift test --filter RouterRecoveryPolicyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BamKit/Sources/BamCore/RouterRecovery.swift BamKit/Tests/BamCoreTests/RouterRecoveryPolicyTests.swift
git commit -m "feat(core): per-reason router recovery budgets with pausedUntil accessor"
```

---

## Task 4 (A2 wiring): Engine uses RecoveryReason

**Files:**
- Modify: `BamKit/Sources/AudioEngine/CoreAudioEngine.swift` (`checkRouterHealth`, `recoverRouterAfterHealthFailure`)

**Interfaces:**
- Consumes: `RecoveryReason`, `recordAttempt(reason:)` from Task 3.
- Produces: `recoverRouterAfterHealthFailure(signature:reason: RecoveryReason, resetSourceIDs:)`.

- [ ] **Step 1: Change the helper signature**

In `recoverRouterAfterHealthFailure` (`:579`), change `reason: String` → `reason: RecoveryReason`. Update the internal `recordAttempt` call (`:598`) — it already passes `reason:`, now typed. Update the `bamLog("router recovery: \(reason)")` line to `\(reason.rawValue)`.

- [ ] **Step 2: Update the four call sites in `checkRouterHealth`**

Replace the string literals with enum cases:

```swift
// aggregate stalled (~:454)
recoverRouterAfterHealthFailure(signature: signature, reason: .aggregateStalled)
// output format drift (~:465)
recoverRouterAfterHealthFailure(signature: signature, reason: .outputFormatDrift)
// tap format drift (~:481)
recoverRouterAfterHealthFailure(signature: signature, reason: .tapFormatDrift, resetSourceIDs: Set(formatBad))
// source tap stalled (~:503)
recoverRouterAfterHealthFailure(signature: signature, reason: .sourceTapStalled, resetSourceIDs: Set(sourceFrameBad))
```

- [ ] **Step 3: Build + run existing engine tests**

Run: `cd BamKit && swift build && swift test --filter AudioEngineTests`
Expected: builds; existing tests still pass.

- [ ] **Step 4: Commit**

```bash
git add BamKit/Sources/AudioEngine/CoreAudioEngine.swift
git commit -m "refactor(engine): drive recovery with typed RecoveryReason"
```

---

## Task 5 (A3): Re-arm timer after cooldown pause

**Files:**
- Modify: `BamKit/Sources/AudioEngine/CoreAudioEngine.swift`

**Interfaces:**
- Consumes: `pausedUntil(for:)` (Task 3), `RecoveryReason`.
- Produces: private `rearmTasks: [RecoveryReason: Task<Void, Never>]`; `scheduleRecoveryRearm(reason:signature:)`.

- [ ] **Step 1: Add the re-arm task store**

Near the recovery state on the actor (by `routerRecoveryPolicy`, `:55`), add:

```swift
private var rearmTasks: [RecoveryReason: Task<Void, Never>] = [:]
```

- [ ] **Step 2: Schedule a re-arm when paused**

In `recoverRouterAfterHealthFailure`, in the `guard case .attempting = event else { ... }` branch (the paused/give-up path, `:602-608`) — before `return`, schedule a re-arm keyed by reason:

```swift
guard case .attempting = event else {
    router = nil
    routerTapSig = nil
    routerHealthBaseline = nil
    restoreGuardedOutput()
    if case .paused = event { scheduleRecoveryRearm(reason: reason, signature: signature) }
    return
}
```

- [ ] **Step 3: Implement the re-arm**

Add:

```swift
private func scheduleRecoveryRearm(reason: RecoveryReason, signature: String) {
    guard let until = routerRecoveryPolicy.pausedUntil(for: reason) else { return }
    rearmTasks[reason]?.cancel()
    let delay = max(0, until.timeIntervalSinceNow)
    rearmTasks[reason] = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else { return }
        await self.retryAfterRearm(reason: reason, signature: signature)
    }
}

private func retryAfterRearm(reason: RecoveryReason, signature: String) {
    rearmTasks[reason] = nil
    // Only retry if this router generation is still the one that paused, and it is
    // actually still offline (router got torn down on pause).
    guard routerTapSig == nil || routerTapSig == signature, let config = routerConfig else { return }
    bamLog("router recovery re-arm fired: \(reason.rawValue)")
    _ = startRouter(config: config)
}
```

- [ ] **Step 4: Cancel re-arms on stop/reset**

In `stopRouter()` (`:771`) and `resetRouterRecovery()` (`:676`), add:

```swift
for t in rearmTasks.values { t.cancel() }
rearmTasks.removeAll()
```

- [ ] **Step 5: Build + test**

Run: `cd BamKit && swift build && swift test --filter AudioEngineTests`
Expected: builds; existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add BamKit/Sources/AudioEngine/CoreAudioEngine.swift
git commit -m "feat(engine): re-arm paused recovery after cooldown so stalls aren't stranded"
```

---

## Task 6 (A4): Auto-reset policy on sustained health

**Files:**
- Modify: `BamKit/Sources/AudioEngine/CoreAudioEngine.swift` (`RouterHealthState`, `checkRouterHealth`)

**Interfaces:**
- Consumes: `routerRecoveryPolicy.reset()`.
- Produces: `RouterHealthState.healthyStreak`.

- [ ] **Step 1: Add the streak field**

In `struct RouterHealthState` (`:78`), add:

```swift
var healthyStreak = 0
```

- [ ] **Step 2: Track sustained health and reset the budget**

At the end of `checkRouterHealth`, replace the final `return true` (`:507`) with:

```swift
    // A fully-clean sample: nothing stale, no drift, no idle source flagged.
    let healthy = state.staleSamples == 0
        && state.noInputSamples == 0
        && state.outputFormatDriftSamples == 0
        && sourceFrameBad.isEmpty
        && formatBad.isEmpty
    if healthy {
        state.healthyStreak += 1
        if state.healthyStreak == 5 {   // ~10s at the 2s poll
            routerRecoveryPolicy.reset()
            bamLog("router recovery budget reset after sustained health")
        }
    } else {
        state.healthyStreak = 0
    }
    return true
```

(Note: `formatBad` and `sourceFrameBad` are already in scope at that point in the function.)

- [ ] **Step 3: Build + test**

Run: `cd BamKit && swift build && swift test --filter AudioEngineTests`
Expected: builds; existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add BamKit/Sources/AudioEngine/CoreAudioEngine.swift
git commit -m "feat(engine): reset recovery budget only after sustained health"
```

---

## Task 7 (A7): Guarded mute around output switches

**Files:**
- Modify: `BamKit/Sources/AudioEngine/CoreAudioEngine.swift` (`startRouter`, `recoverRouterAfterHealthFailure`)

**Interfaces:**
- Consumes: `Self.setDeviceMuted(uid:_:)`, `Self.deviceVolume(uid:)`, `Self.setDeviceVolume(uid:_:)`.
- Produces: `performGuardedOutputRebuild(uids: Set<String>, unmute: Bool, _ rebuild: () -> Void)`.

- [ ] **Step 1: Add the shared guard helper**

```swift
/// Mute the given output devices at the OS level, run `rebuild`, then restore
/// their volume and (unless master is muted) unmute — so a device switch or
/// aggregate rebuild can never blast at full volume before the fade-in settles.
private func performGuardedOutputRebuild(uids: Set<String>, unmute: Bool, _ rebuild: () -> Void) {
    let volumes: [String: Float] = Dictionary(uniqueKeysWithValues:
        uids.compactMap { uid in Self.deviceVolume(uid: uid).map { (uid, $0) } })
    for uid in uids { Self.setDeviceMuted(uid: uid, true) }
    rebuild()
    for uid in uids {
        if let v = volumes[uid] { Self.setDeviceVolume(uid: uid, v) }
        if unmute { Self.setDeviceMuted(uid: uid, false) }
    }
}
```

- [ ] **Step 2: Capture the previous bound UID in `startRouter`**

At the top of `startRouter`, before `_boundOutputUID` is reassigned (`:269`), add:

```swift
let previousBoundUID = _boundOutputUID
```

- [ ] **Step 3: Guard the aggregate rebuild when the output changed**

The aggregate rebuild block (`:373-410`, from `router = nil` through `router = agg; routerTapSig = aggSig; ...`). Wrap only that build+assign in the guard when `outputUID != previousBoundUID`:

```swift
let outputChanged = previousBoundUID != nil && previousBoundUID != outputUID
var builtOK = true
let doRebuild = {
    // ... existing rebuild body: RouterAggregate(...), applyRouterGains, router = agg,
    // routerTapSig = aggSig, routerHealthBaseline = ..., startRouterHealthMonitor,
    // set builtOK = false on the failure guard instead of early-returning.
}
if outputChanged {
    let guarded: Set<String> = Set([previousBoundUID, outputUID].compactMap { $0 })
    performGuardedOutputRebuild(uids: guarded, unmute: !config.masterMuted, doRebuild)
} else {
    doRebuild()
}
```

Implementation note for the engineer: the current rebuild does `return RouterStatus(...)` on aggregate-build failure mid-function. Refactor so the failure path sets a captured `builtOK = false` (and stashes the failure `RouterStatus`), then after the guard, `if !builtOK { return failureStatus }`. Do **not** early-return from inside the `doRebuild` closure. Keep the success path (`return .ok`) after the guard.

- [ ] **Step 4: Refactor recovery to reuse the guard**

In `recoverRouterAfterHealthFailure`, the manual mute/restore (`:585-597` + the two `restoreGuardedOutput()` calls) now duplicates the helper. Replace the manual mute + `restoreGuardedOutput` with a single `performGuardedOutputRebuild(uids: [outputUID], unmute: !config.masterMuted) { _ = startRouter(config: config) }` in the `.attempting` path. Keep the paused path's device restore (mute was set) by routing it through the same helper with an empty rebuild, or by leaving the device unmuted since no rebuild occurred — the engineer picks the minimal correct form; the acceptance test in Step 5 pins the behavior.

- [ ] **Step 5: Write an engine test for the guard sequence**

Add to `AudioEngineTests` a test using the existing device-I/O seam (the same one `RouterSmokeTests`/`MixerDeviceIntegrationTests` use to fake CoreAudio). Assert:
- On a config whose output UID changes, `setDeviceMuted(uid, true)` is observed **before** the aggregate is (re)built and `setDeviceMuted(uid, false)` **after**.
- On a gain-only `updateRouterGains` (no output change), no mute toggle occurs.

Match the fake/mock pattern already present in those test files (do not invent a new CoreAudio mock). If the current seam cannot observe device mute calls, extend it minimally (add a recording hook alongside the existing test factory `setChangeListenerFactoryForTests`, `:40`).

- [ ] **Step 6: Build + test**

Run: `cd BamKit && swift build && swift test --filter AudioEngineTests`
Expected: builds; new guard test + existing tests pass.

- [ ] **Step 7: Commit**

```bash
git add BamKit/Sources/AudioEngine/CoreAudioEngine.swift BamKit/Tests/AudioEngineTests
git commit -m "feat(engine): guard output-device switches with mute so they never blast"
```

---

## Task 8 (A5): DSP kernels — scalar reference + vDSP, golden-buffer tests

**Files:**
- Create: `BamKit/Sources/AudioEngine/DSPKernels.swift`
- Test: `BamKit/Tests/AudioEngineTests/DSPKernelTests.swift`

**Interfaces:**
- Produces (all `@inline(__always)`, raw pointers + counts only, no allocation):
  - `enum DSPKernels`
  - `sumScaledScalar(src: UnsafePointer<Float>, stride: Int, gain: Float, dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int)`
  - `sumScaledVDSP(...)` — same signature.
  - `sumOfSquaresScalar(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float`
  - `sumOfSquaresVDSP(...)` — same.
  - `peakMagnitudeScalar(_ buf: UnsafePointer<Float>, count: Int) -> Float`
  - `peakMagnitudeVDSP(...)` — same.

- [ ] **Step 1: Write the failing golden-buffer tests**

Create `DSPKernelTests.swift` (XCTest — match `AudioEngineTests` framework):

```swift
import XCTest
@testable import AudioEngine

final class DSPKernelTests: XCTestCase {
    private func randomBuffer(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: s >> 32)) / Float(Int32.max)
        }
    }

    func testSumScaledMatches() {
        let frames = 512
        let src = randomBuffer(frames, seed: 1)
        let gain: Float = 0.37
        var a = [Float](repeating: 0.1, count: frames)
        var b = a
        src.withUnsafeBufferPointer { sp in
            a.withUnsafeMutableBufferPointer { ap in
                DSPKernels.sumScaledScalar(src: sp.baseAddress!, stride: 1, gain: gain,
                                           dst: ap.baseAddress!, dstStride: 1, frames: frames)
            }
            b.withUnsafeMutableBufferPointer { bp in
                DSPKernels.sumScaledVDSP(src: sp.baseAddress!, stride: 1, gain: gain,
                                         dst: bp.baseAddress!, dstStride: 1, frames: frames)
            }
        }
        for i in 0..<frames { XCTAssertLessThan(abs(a[i] - b[i]), 1e-6, "idx \(i)") }
    }

    func testSumOfSquaresMatches() {
        let src = randomBuffer(777, seed: 2)
        let (ss, vv): (Float, Float) = src.withUnsafeBufferPointer { sp in
            (DSPKernels.sumOfSquaresScalar(src: sp.baseAddress!, stride: 1, frames: sp.count),
             DSPKernels.sumOfSquaresVDSP(src: sp.baseAddress!, stride: 1, frames: sp.count))
        }
        XCTAssertLessThan(abs(ss - vv) / max(1, ss), 1e-6)
    }

    func testPeakMatches() {
        let src = randomBuffer(1024, seed: 3)
        let (ps, pv): (Float, Float) = src.withUnsafeBufferPointer { sp in
            (DSPKernels.peakMagnitudeScalar(sp.baseAddress!, count: sp.count),
             DSPKernels.peakMagnitudeVDSP(sp.baseAddress!, count: sp.count))
        }
        XCTAssertEqual(ps, pv, accuracy: 1e-6)
    }

    func testNoNaN() {
        let src = [Float](repeating: 0, count: 64)
        let ss = src.withUnsafeBufferPointer {
            DSPKernels.sumOfSquaresVDSP(src: $0.baseAddress!, stride: 1, frames: $0.count)
        }
        XCTAssertFalse(ss.isNaN)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BamKit && swift test --filter DSPKernelTests`
Expected: FAIL — `DSPKernels` undefined.

- [ ] **Step 3: Implement the kernels**

Create `DSPKernels.swift`:

```swift
import Accelerate

enum DSPKernels {
    @inline(__always)
    static func sumScaledScalar(src: UnsafePointer<Float>, stride: Int, gain: Float,
                                dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var i = 0
        while i < frames {
            dst[i * dstStride] += src[i * stride] * gain
            i += 1
        }
    }

    @inline(__always)
    static func sumScaledVDSP(src: UnsafePointer<Float>, stride: Int, gain: Float,
                              dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var g = gain
        // dst = src*g + dst  (multiply-add into destination)
        vDSP_vsma(src, vDSP_Stride(stride), &g, dst, vDSP_Stride(dstStride),
                  dst, vDSP_Stride(dstStride), vDSP_Length(frames))
    }

    @inline(__always)
    static func sumOfSquaresScalar(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float {
        var acc: Float = 0
        var i = 0
        while i < frames { let s = src[i * stride]; acc += s * s; i += 1 }
        return acc
    }

    @inline(__always)
    static func sumOfSquaresVDSP(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float {
        var acc: Float = 0
        vDSP_svesq(src, vDSP_Stride(stride), &acc, vDSP_Length(frames))
        return acc
    }

    @inline(__always)
    static func peakMagnitudeScalar(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        var i = 0
        while i < count { let a = abs(buf[i]); if a > peak { peak = a }; i += 1 }
        return peak
    }

    @inline(__always)
    static func peakMagnitudeVDSP(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(buf, 1, &peak, vDSP_Length(count))
        return peak
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd BamKit && swift test --filter DSPKernelTests`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add BamKit/Sources/AudioEngine/DSPKernels.swift BamKit/Tests/AudioEngineTests/DSPKernelTests.swift
git commit -m "feat(engine): add vDSP DSP kernels with scalar reference + golden-buffer tests"
```

---

## Task 9 (A5): Wire IOProc to kernels, single output pass

**Files:**
- Modify: `BamKit/Sources/AudioEngine/RouterAggregate.swift` (`startIO` IOProc block, `:260-442`)

**Interfaces:**
- Consumes: `DSPKernels` (Task 8).
- Produces: unchanged external behavior; internally kernel-based.

- [ ] **Step 1: Replace the inner sum/RMS loops**

In the input walk (`:321-363`), replace the hand-rolled per-channel inner sample loops with kernel calls. For each input channel `localCh` of tap `tIdx` with gain `g`, targeting output pointer `outPtr` (`out`/`rightOut`) at `dstStride` (`1` for planar, `firstOutCh` for interleaved with offset `dstCh`):

```swift
let srcBase = p + localCh
DSPKernels.sumScaledVDSP(src: srcBase, stride: bch, gain: g,
                         dst: dstPtr, dstStride: dstStride, frames: frames)
let ss = DSPKernels.sumOfSquaresVDSP(src: srcBase, stride: bch, frames: frames)
```

Keep the existing meter accumulation (`sumSq[tIdx] += ss`, L/R split) exactly as-is. `dstPtr`/`dstStride` selection reproduces the current three branches (planar-right, planar-left, interleaved).

- [ ] **Step 2: Fold peak into a single output pass**

The fade-in + peak pass (`:388-408`) already walks the output once and computes `peak`. Leave the fade-in there but replace the manual peak tracking with the running max already computed; the second dedicated limiter scan (`:416-429`) stays for now (limiter is replaced in Task 11). No separate `peakMagnitude` pass is added — the existing fade loop yields `peak`. (This step is a no-op if the fade loop already produces `peak`; confirm no redundant peak scan was introduced.)

- [ ] **Step 3: Build + run golden + smoke tests**

Run: `cd BamKit && swift build && swift test --filter AudioEngineTests`
Expected: builds; `RouterSmokeTests`, `MixerTests`, `DSPKernelTests` pass.

- [ ] **Step 4: Manual sanity (device present)**

If on a machine with audio: launch the app, route one app, confirm audio + meters look identical to pre-change. Record result in the commit body.

- [ ] **Step 5: Commit**

```bash
git add BamKit/Sources/AudioEngine/RouterAggregate.swift
git commit -m "perf(engine): route IOProc sum/RMS through vDSP kernels"
```

---

## Task 10 (G): Lookahead envelope limiter — pure + tested

**Files:**
- Modify: `BamKit/Sources/AudioEngine/AudioLimiter.swift`
- Test: `BamKit/Tests/AudioEngineTests/AudioLimiterTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct LimiterConfig { var attackMs, releaseMs, lookaheadMs, ceiling: Float; init defaults 1, 100, 1.5, 1.0 }`
  - `static func lookaheadFrames(sampleRate: Double, lookaheadMs: Float) -> Int`
  - `static func attackCoeff/releaseCoeff(sampleRate:_, ms:) -> Float`
  - `static func nextEnvelope(current: Float, targetGain: Float, attackCoeff: Float, releaseCoeff: Float) -> Float`
  - `static func targetGain(forPeak: Float, ceiling: Float) -> Float`
- Keep the old `scale(forPeak:)` / `nextScale(...)` until Task 11 removes their last caller.

- [ ] **Step 1: Write failing tests**

Create `AudioLimiterTests.swift`:

```swift
import XCTest
@testable import AudioEngine

final class AudioLimiterTests: XCTestCase {
    func testTransparentBelowCeiling() {
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 0.8, ceiling: 1.0), 1.0, accuracy: 0)
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 1.0, ceiling: 1.0), 1.0, accuracy: 0)
    }

    func testReducesAboveCeiling() {
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 2.0, ceiling: 1.0), 0.5, accuracy: 1e-6)
    }

    func testAttackIsFasterThanRelease() {
        let sr = 48000.0
        let a = AudioLimiter.attackCoeff(sampleRate: sr, ms: 1)
        let r = AudioLimiter.releaseCoeff(sampleRate: sr, ms: 100)
        // attack coefficient moves the envelope further per sample than release
        let downAttack = AudioLimiter.nextEnvelope(current: 1.0, targetGain: 0.5, attackCoeff: a, releaseCoeff: r)
        let upRelease  = AudioLimiter.nextEnvelope(current: 0.5, targetGain: 1.0, attackCoeff: a, releaseCoeff: r)
        XCTAssertLessThan(downAttack, 1.0)
        XCTAssertGreaterThan(upRelease, 0.5)
        XCTAssertLessThan(1.0 - downAttack, 1.0)          // moved down
        XCTAssertTrue(upRelease < 1.0)                     // release not instant
    }

    func testEnvelopeNoOvershootNoNaN() {
        let e = AudioLimiter.nextEnvelope(current: 1.0, targetGain: 0.5, attackCoeff: 0.9, releaseCoeff: 0.01)
        XCTAssertFalse(e.isNaN)
        XCTAssertGreaterThanOrEqual(e, 0.5)
        XCTAssertLessThanOrEqual(e, 1.0)
    }

    func testLookaheadFrames() {
        XCTAssertEqual(AudioLimiter.lookaheadFrames(sampleRate: 48000, lookaheadMs: 1.5), 72)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BamKit && swift test --filter AudioLimiterTests`
Expected: FAIL — new symbols undefined.

- [ ] **Step 3: Implement**

Add to `AudioLimiter.swift`:

```swift
struct LimiterConfig {
    var attackMs: Float = 1
    var releaseMs: Float = 100
    var lookaheadMs: Float = 1.5
    var ceiling: Float = 1.0
}

extension AudioLimiter {
    static func lookaheadFrames(sampleRate: Double, lookaheadMs: Float) -> Int {
        max(1, Int((Double(lookaheadMs) / 1000.0 * sampleRate).rounded()))
    }

    static func attackCoeff(sampleRate: Double, ms: Float) -> Float {
        coeff(sampleRate: sampleRate, ms: ms)
    }

    static func releaseCoeff(sampleRate: Double, ms: Float) -> Float {
        coeff(sampleRate: sampleRate, ms: ms)
    }

    private static func coeff(sampleRate: Double, ms: Float) -> Float {
        guard ms > 0, sampleRate > 0 else { return 1 }
        // one-pole time constant: e^(-1 / (tau * fs))
        let tau = Double(ms) / 1000.0
        return Float(exp(-1.0 / (tau * sampleRate)))
    }

    /// True-peak → gain that would bring it to the ceiling (1.0 if already under).
    static func targetGain(forPeak peak: Float, ceiling: Float) -> Float {
        guard peak.isFinite, peak > ceiling, peak > 0 else { return 1 }
        return ceiling / peak
    }

    /// One-pole envelope toward `targetGain`. Attack (target below current) uses the
    /// attack coefficient; release (target above) uses the release coefficient.
    static func nextEnvelope(current: Float, targetGain: Float,
                             attackCoeff: Float, releaseCoeff: Float) -> Float {
        let c = current.isFinite ? min(max(current, 0), 1) : 1
        let t = targetGain.isFinite ? min(max(targetGain, 0), 1) : 1
        let k = t < c ? attackCoeff : releaseCoeff
        let next = t + (c - t) * k
        return min(max(next, 0), 1)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd BamKit && swift test --filter AudioLimiterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BamKit/Sources/AudioEngine/AudioLimiter.swift BamKit/Tests/AudioEngineTests/AudioLimiterTests.swift
git commit -m "feat(engine): lookahead envelope limiter primitives (pure, tested)"
```

---

## Task 11 (G): Integrate lookahead limiter into the IOProc

**Files:**
- Modify: `BamKit/Sources/AudioEngine/RouterAggregate.swift` (`startIO` preallocation + IOProc limiter section)

**Interfaces:**
- Consumes: `LimiterConfig`, `AudioLimiter.lookaheadFrames/attackCoeff/releaseCoeff/targetGain/nextEnvelope` (Task 10), `DSPKernels.peakMagnitudeVDSP` (Task 8).
- Produces: limiter with ~1.5 ms lookahead; removes `AudioLimiter.scale/nextScale` usage.

- [ ] **Step 1: Preallocate lookahead state in `startIO`**

Alongside the existing scratch (`:238-244`), add a delay ring sized to `lookaheadFrames × maxOutputChannels` and envelope/coeff scalars. Compute `lookaheadFrames` from the aggregate's output sample rate (available via the health baseline / device query used at build). Preallocate:

```swift
let laFrames = AudioLimiter.lookaheadFrames(sampleRate: outSampleRate, lookaheadMs: 1.5)
// ring buffer: laFrames * maxOutCh floats, zeroed; write index; envelope=1; coeffs precomputed
```

Store pointers on the class like the other `*Scratch` fields (add stored `var` pointers + free them in `teardown`, `:464`).

- [ ] **Step 2: Replace the limiter section**

Replace the old limiter block (`:409-431`, `AudioLimiter.scale`/`nextScale`) with the lookahead path:
1. Compute the current buffer's true peak over the output via `DSPKernels.peakMagnitudeVDSP` (already have `peak` from the fade pass — reuse it as the *incoming* peak for the delayed samples).
2. Delay the output by `laFrames` through the ring (write current output into the ring, read out the delayed samples that are what actually goes to the device).
3. `target = AudioLimiter.targetGain(forPeak: windowedPeak, ceiling: 1.0)`.
4. `env = AudioLimiter.nextEnvelope(current: env, targetGain: target, attackCoeff:, releaseCoeff:)` per frame (or per-buffer block for cost; per-frame is simplest and correct).
5. Multiply the delayed output by `env` (vDSP_vsmul) before it leaves the block.

Keep `dLimiterHits` incrementing when `env < 1`. Keep the fade-in applied *before* the limiter (so start-up ramp is unaffected).

Engineer note: the ring introduces `laFrames` of latency uniformly across channels — that is the accepted ~1.5 ms. Ensure the ring read/write use only raw pointer arithmetic (no `Range`/generics) per the RT constraint.

- [ ] **Step 3: Remove dead limiter API**

Delete `AudioLimiter.scale(forPeak:)` and `nextScale(...)` once this is the only limiter path. Remove any now-unused test for them.

- [ ] **Step 4: Build + full test**

Run: `cd BamKit && swift build && swift test`
Expected: all pass (DSP, limiter, recovery, smoke, integration).

- [ ] **Step 5: Manual audio verification (device present)**

Launch app; confirm: (a) normal playback bit-transparent to ear, (b) no pumping when one source spikes hot, (c) switching output devices no longer blasts. Record in commit body.

- [ ] **Step 6: Commit**

```bash
git add BamKit/Sources/AudioEngine/RouterAggregate.swift BamKit/Sources/AudioEngine/AudioLimiter.swift BamKit/Tests
git commit -m "feat(engine): transparent lookahead limiter on the summed bus (no pumping)"
```

---

## Final Verification

- [ ] `cd BamKit && swift test` — all green.
- [ ] `xcodegen generate && xcodebuild -project bam.xcodeproj -scheme bam -configuration Debug -derivedDataPath .build test` — app target + `AppTests` green.
- [ ] Manual: virtualSlot config rejected; output switch silent; no limiter pumping; meters unchanged.
- [ ] Open PR from `engine-improvements`.

---

## Self-Review Notes

**Spec coverage:** A1→T2, A2→T3+T4, A3→T5, A4→T6, A5→T8+T9, A6→T1, A7→T7, G→T10+T11. F3.2 deferred (documented in spec). All acceptance criteria mapped.

**Known implementer latitude (not placeholders — real seams):** T7 Step 5 and T11 Step 2 reference the existing CoreAudio test seam and IOProc pointer layout that must be read in-file; exact fake-hook wiring and ring-buffer indexing depend on current code the implementer has open. All signatures, types, and test code are concrete.
