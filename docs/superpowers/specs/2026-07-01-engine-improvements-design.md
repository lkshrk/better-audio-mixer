# Engine Improvements — Design Spec

**Date:** 2026-07-01
**Status:** Approved (brainstorm) → ready for implementation plan
**Scope:** `BamKit/Sources/AudioEngine`, `BamKit/Sources/BamCore`, `App/`
**Out of scope:** Stream Deck plugin autostart (separate spec — research in progress)

## Goal

Close a routing correctness hole, make automatic router-recovery throttling
genuinely cause-aware, speed up the real-time IOProc without regressing audio,
and remove two audible defects (output-switch volume blast, limiter pumping).
**Audio quality is a first-class acceptance criterion** — no change may perceptibly
alter normal playback.

## Background

Findings from a codebase analysis of the CoreAudio engine (2026-07-01):

- The live engine sums every process tap into **one** hardware-clocked aggregate
  (`RouterAggregate` IOProc). The model's `MixDestination.virtualSlot` +
  `BAM_UID` driver machinery is represented and validated but **unused** by the
  live render path.
- Automatic recovery *detects* failure causes precisely (`RouterFailureCause`,
  health monitor) but the *throttle* (`RouterRecoveryPolicy`) pools all reasons
  into one budget — cause-blind.
- The IOProc uses hand-rolled scalar loops for sum/RMS/limiter and walks the
  output buffer twice.
- User-initiated output switches rebuild the aggregate **without** the OS-mute
  guard that the recovery path already uses → a brief max-volume blast.
- The bus limiter uses instant attack + a crude 1%-per-buffer release → audible
  pumping when one source spikes.

## Decisions (from brainstorm)

| Topic | Decision |
|-------|----------|
| Scope | Everything: F1–F4 + audio quality + output-switch guard |
| `virtualSlot` (F2) | **Guardrail + defer.** Reject non-hardware dests in validation. Keep model + driver. Multi-output = future project. |
| IOProc rewrite (F1) | **vDSP + golden-buffer transparency tests.** |
| Limiter pumping (F1.3) | **In scope.** Lookahead envelope limiter, ~1.5 ms latency accepted. |
| Stream Deck autostart | **Separate spec.** |

## Work Items

| # | Source | Action | Risk |
|---|--------|--------|------|
| A1 | F2.1 | `validateRouting` rejects non-hardware mix dests | low |
| A2 | F4.1 | Per-reason recovery budgets | low |
| A3 | F4.2 | Re-arm timer after cooldown pause | med |
| A4 | F4.3 | Auto-reset policy on sustained health | low |
| A5 | F1.1 + F1.2 | Extract DSP → vDSP + golden-buffer tests, fold peak into sum pass | med-high |
| A6 | F3.3 | Fix misleading recovery log wording | trivial |
| A7 | topic 3 | Guarded mute around every output switch | med |
| G  | F1.3 | Lookahead envelope limiter (folds into A5) | med |

**Deferred with documented rationale:**
- **F3.2 make-before-break output switch** — blocked by keeping the fixed
  `BAM_UID` scheme (guardrail decision keeps the driver). Revisit only if
  `virtualSlot` is ever deleted. A7 already removes the audible symptom.

## Detailed Design

### A1 — virtualSlot guardrail

`BamConfig.validateRouting()` currently accepts any `MixDestination`. Add a rule:
if any `mix.dest` is `.virtualSlot`, throw a new
`BamConfigError.unsupportedVirtualDestination(mix:)`. This prevents a config from
silently losing audio to the single default output when it *looks* like it routes
to a virtual device.

- **File:** `BamKit/Sources/BamCore/BamConfig.swift`
- **Error:** extend `BamConfigError` with `.unsupportedVirtualDestination(String)`
  + `description`.
- **Test:** `BamConfigTests` / `RoutingModelTests` — a `virtualSlot` config
  throws; a `hardware` config passes.

### A2 — Per-reason recovery budgets

Replace the free-string `reason:` in the recovery path with a type-safe enum, and
give each reason its own throttle budget so one flapping failure mode cannot
starve another's retries.

- **New type (BamCore, `RouterRecovery.swift`):**
  ```
  enum RecoveryReason: String, Sendable, Equatable {
      case aggregateStalled, outputFormatDrift, tapFormatDrift, sourceTapStalled
  }
  ```
- **`RouterRecoveryPolicy`** changes:
  - `attempts: [Date]` → `attempts: [RecoveryReason: [Date]]`
  - `pausedUntil: Date?` → `pausedUntil: [RecoveryReason: Date]`
  - `recordAttempt(reason: RecoveryReason, now:)` throttles per reason;
    `.paused`/`.attempting` semantics unchanged per reason.
  - `reset()` clears all reasons.
- **`RouterRecoveryEvent`** payload: keep human strings for UI, but carry the
  `RecoveryReason` where the engine constructs events.
- **Engine:** `recoverRouterAfterHealthFailure` takes `RecoveryReason` instead of
  a `String`; call sites in `checkRouterHealth` updated.
- **Tests:** extend `RouterRecoveryPolicyTests` — independent budgets: exhausting
  `outputFormatDrift` still lets `aggregateStalled` attempt.

### A3 — Paused re-arm timer

Today, when `recordAttempt` returns `.paused`, the health task is cancelled and
nothing re-checks until an unrelated `routerEvent` fires — a stalled+paused
router can be stranded until the cooldown-then-nothing.

- **Engine:** when a `.paused(cooldown:)` event is produced, schedule a
  cancellable `Task` that sleeps until `pausedUntil` for that reason, then
  re-runs `checkRouterHealth`/retry. One live re-arm task per reason; a new
  attempt replaces/cancels the prior timer so they cannot stack.
- **Injectable clock:** `RouterRecoveryPolicy` already accepts `now:` — expose
  the computed `pausedUntil` so the engine can schedule against it (and tests can
  drive it deterministically).
- **Test:** policy reports `pausedUntil`; a fake-clock test asserts a single
  re-arm fires after cooldown and dedupes.

### A4 — Auto-reset on sustained health

`startRouter` emits `.recovered` optimistically without resetting the policy, so
repeated recover→fail cycles exhaust the budget even when each recovery briefly
worked.

- **Engine:** add `healthyStreak: Int` to `RouterHealthState`. In
  `checkRouterHealth`, increment on a fully-healthy sample, reset to 0 on any
  degradation. When `healthyStreak` crosses a threshold (~5 samples ≈ 10 s at the
  2 s poll), call `routerRecoveryPolicy.reset()` once.
- The `.recovered` UI event still fires immediately; only the *budget* waits for
  proven stability.
- **Test:** simulate recover→fail→recover; assert budget only clears after the
  sustained-health threshold.

### A5 — DSP extraction + vDSP + golden tests (with A5/G merged)

Extract the RT math out of the IOProc block into pure, testable kernels; provide
a scalar **reference** and a vDSP **fast path** for each; assert equivalence
offline.

- **New file:** `BamKit/Sources/AudioEngine/DSPKernels.swift`
  - `sumTapChannelIntoOutput(...)` — accumulate `input × gain` into an output
    channel (`vDSP_vsma`).
  - `sumOfSquares(...)` — per-tap RMS accumulation (`vDSP_svesq`).
  - `truePeak(...)` — `vDSP_maxmgv`; **folded into the sum pass** so the output
    buffer is walked once, not twice (F1.2).
  - fade-in ramp application (vectorized).
- **RT discipline preserved:** kernels take **raw pointers + counts only** — no
  tuples, no `Range`, no generics on the audio thread (keeps the metadata-lock
  deadlock fix from `RouterAggregate.startIO`). All scratch stays preallocated in
  `startIO`; kernels allocate nothing.
- **IOProc** calls the kernels instead of inline loops.
- **Tests (`AudioEngineTests`, new `DSPKernelTests`):** random + edge-case
  buffers; assert `|vDSP − scalar| < 1e-6` for output samples and every meter
  value; assert no NaN/denormal.

### A6 — Log wording

`recoverRouterAfterHealthFailure(resetSourceIDs:)` logs "rebuilding tap(s)" but
actually rebuilds the whole aggregate via `startRouter`. Correct the log strings
to say the aggregate is rebuilt (dropping the named tap's cache). Cosmetic only,
no behavior change.

- **File:** `BamKit/Sources/AudioEngine/CoreAudioEngine.swift`.

### A7 — Guarded output switch

**Root cause:** user-initiated output switch (`setOutputDevice` → `applyTopology`
→ `startRouter`) rebuilds the aggregate with no OS-mute guard; the new device
outputs at the restored master volume before the fade-in settles → the blast. The
recovery path already guards (mute → rebuild → restore + unmute).

- **Extract** the mute-guard from `recoverRouterAfterHealthFailure` into a shared
  helper on `CoreAudioEngine`:
  ```
  performGuardedOutputRebuild(uids: Set<String>, rebuild: () -> Void)
    → for each uid: capture volume, setDeviceMuted(uid, true)
    → rebuild()
    → for each uid: restore volume; setDeviceMuted(uid, false) unless config.masterMuted
  ```
- **`startRouter`:** when the resolved `outputUID` differs from the previously
  bound UID, run the aggregate rebuild inside `performGuardedOutputRebuild` for
  `{oldUID, newUID}` (deduped). Same-output rebuilds and gain-only edits are **not**
  guarded → they pay nothing.
- **Recovery** reuses the same helper → removes the duplicated mute/unmute block
  (single audited path).
- **Accepted tradeoff:** OS-device mute briefly dips non-bam audio on those
  devices for the switch window (tens of ms) — identical to what recovery already
  does.
- **Tests:** engine-level test (mockable device I/O) asserting mute is asserted
  before rebuild and cleared after on an output change, and *not* toggled on a
  same-output gain edit.

### G — Lookahead envelope limiter

Replace the instant-attack / 1%-release bus scaler with a sample-rate-aware
lookahead envelope limiter. Removes the pumping artifact and transient distortion
while staying transparent below full-scale. Gain reduction on the summed bus is
inherent and retained; only the *artifact* is removed.

- **`AudioLimiter`** becomes pure, testable functions parameterized by:
  - `attackMs ≈ 1`, `releaseMs ≈ 80–120`, `lookaheadMs ≈ 1.5`, `ceiling = 1.0`.
  - time constants → per-sample coefficients from the device sample rate.
- **Lookahead delay buffer + envelope state** preallocated in `startIO` (no RT
  allocation). vDSP handles the delay copy and gain application.
- **True-peak within the lookahead window**; output never exceeds `ceiling`.
- **Transparent:** gain stays exactly `1.0` (bit-exact passthrough) whenever the
  windowed peak ≤ ceiling.
- **Latency:** ~1.5 ms added to all output — **accepted** (inaudible, standard for
  a mixer; the price of a transparent limiter).
- **Tests (extend the golden-buffer harness):**
  - output ≤ ceiling for adversarial hot sums,
  - bit-exact passthrough when windowed peak ≤ 1.0,
  - release envelope monotonic, no NaN/denormal,
  - gain-reduction curve matches the scalar reference within epsilon.

## Data Flow (unchanged shape, faster + safer internals)

```
BamConfig → CoreAudioEngine.startRouter
  → resolve outputUID (guarded if changed, A7)
  → reuse/create ProcessTaps by signature
  → RouterAggregate IOProc:
       sum(tap × gain) [vDSP]  → RMS [vDSP] → fade-in → lookahead limiter [G]
  → RouterSnapshot (meters) → ConsoleViewModel / ControlServer
Health monitor (2 s) → per-reason recovery policy (A2) → re-arm (A3) → auto-reset (A4)
```

## Testing Strategy

- **Pure/offline** wherever possible: DSP kernels, limiter, recovery policy, and
  config validation are all pure and unit-tested with no CoreAudio.
- **Golden-buffer** equivalence for every vDSP kernel and the limiter (epsilon
  `1e-6`), guarding audio transparency.
- **Fake-clock** tests for recovery re-arm and auto-reset (policy already takes
  `now:`).
- **Engine tests** for the guarded-switch mute sequencing.
- Existing `RouterSmokeTests` / `MixerDeviceIntegrationTests` remain the
  integration backstop.

## Build / Sequencing

Ship in risk order, tests green before advancing:

1. **A6** (log wording — trivial)
2. **A1** (guardrail + test)
3. **A2** (`RecoveryReason` + per-reason budgets + tests)
4. **A3** (re-arm timer + fake-clock test)
5. **A4** (auto-reset + test)
6. **A7** (guarded-switch helper + refactor recovery to reuse + test)
7. **A5 + G** (DSP extraction, vDSP, lookahead limiter, golden-buffer harness) — last, riskiest RT work, with the strongest test net

## Acceptance Criteria

- No config with a `virtualSlot` destination can be applied (rejected at
  validation).
- Each recovery reason throttles independently; a paused reason auto-re-arms
  after cooldown; the budget resets only after sustained health.
- IOProc uses vDSP kernels; golden-buffer tests pass at `1e-6`; audio is
  perceptibly unchanged.
- Switching output devices produces **no** volume blast (guarded mute verified).
- The limiter no longer pumps on source spikes and is bit-exact transparent below
  full-scale.
- All existing tests still pass.
