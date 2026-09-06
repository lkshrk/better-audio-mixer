# Persistent audio membership implementation

Implemented the first prototype from [the research](2026-09-06-dynamic-audio-membership-research.md). This is source work, not a validated fix for the reported full-volume burst. No installation, restart, device probe, routing change or playback test was performed.

## Behavior

- Configured application sources retain tap slots when their process list becomes empty. Process launch/exit changes membership through `kAudioTapPropertyDescription` without replacing the tap or stopping/recreating the shared aggregate. Existing gain objects, callback state and limiter stay alive.
- Membership changes still use the existing hardware-mute guard. Source and remainder updates are separate HAL writes; this prototype does not claim an atomic or inaudible transfer.
- The tap update preserves UUID, device/stream, capture mode, privacy and mute behavior. Notification plus matching description readback is required; a failed update cannot fall through to tap replacement or pass the no-op preflight.
- Structural source/device changes and recovery retain protected aggregate rebuilding. The inaccurate claim that retained `.mutedWhenTapped` taps guarantee suppression across a stopped reader was removed.
- Hardware control setters now subscribe before mutation, validate device identity, and confirm the requested state after notification. Already-correct states avoid redundant writes. Each property has a 500 ms confirmation timeout.
- Mute, silence and unity checks are exact. Other volume targets allow at most 0.002 scalar and 2% relative rounding, covering the observed 0.12 → 0.121502 device response. Each channel's requested calibration is preserved. Coarser devices fail closed rather than accepting arbitrary readback.
- Start success requires a completed valid callback that started after the edits/gain publication, with unchanged tap formats. Invalid callback layouts zero the supplied outputs. Silent/null input slots may be idle sources; missing channel slots do not authorize restoration. Callback evidence does not prove original-source suppression.

## Failure and recovery

HAL notifications carry no request identifier or cancellation guarantee. An accepted write can complete after its confirmation times out. A later matching readback cannot establish that the earlier request was cancelled.

- An unconfirmed tap update remains uncertain for that tap's lifetime. Ordinary retries keep output protected. Recovery needs a protected full router teardown that destroys the uncertain tap before replacement; this prototype does not automatically substitute a replacement in the failed membership call.
- An accepted volume or unmute request that fails confirmation marks that device identity uncertain. Later releases/volume writes are blocked. Mute is still attempted with a forced write, but does not authorize teardown or restoration. The latch is not cleared by matching readback; a new hardware identity is required within the process. Do not use an app restart to infer that pending HAL requests are cancelled.
- Partial mute restoration attempts re-protect every saved channel. Failed volume restoration never proceeds to unmute.
- Follow-up P1 fix: failed live volume controls immediately attempt all-channel mute outside the shared write-state lock, pinned to the original device identity. The App retains guard ownership/latest target and surfaces failure instead of silently disabling volume control.
- Follow-up P2 fix: output validation uses the actual buffer configuration and every output stream's virtual format, supporting the previously rejected two-mono-stream layout. Stream discovery stays outside the callback.

## Validation

Deterministic tests cover stable empty/active source slots, helper churn, structural-change classification, unchanged tap capture/mute settings, callback-start versus completion ordering, invalid/null buffer layouts, delayed/stale/missing notifications, identity changes, rounding limits, partial channel failure, and uncertain late unmute/volume requests.

Final `make test` passed: 140 package XCTest cases (2 opt-in hardware cases skipped), 53 Swift Testing cases, 49 App tests, 5 diagnostics-collector tests and the WAV analyzer self-test. Independent review found and closed the delayed-unmute/stale-readback issue; the same uncertainty protection covers delayed volume writes. `git diff --check` passed. Release build and Xcode static analysis passed for the configured architectures, with signing disabled; the only reported warning was skipped AppIntents metadata extraction because this app has no AppIntents dependency.

Implementation files: `BamKit/Sources/AudioEngine/{CoreAudioEngine,CoreAudioProperty,ProcessTap,RouterAggregate}.swift`. Tests: `BamKit/Tests/AudioEngineTests/{RouterTopologyTests,PropertyWriteConfirmationTests,RouterCaptureReadinessTests}.swift`. No dependencies added.
Follow-up failure reporting also changes `App/ConsoleViewModel+Volume.swift` and `AppTests/RouterSafetyConcurrencyTests.swift`. Both original reviewers cleared the fixes; 31 focused package tests passed. Final follow-up `make test` passed: 144 package XCTest cases (2 hardware skips), 53 Swift Testing cases, 50 App tests, 5 collector tests and WAV self-test. Release build, Xcode analysis and diff whitespace check passed. Playback trial remains pending confirmation of the off-ear/attenuated physical setup; nothing installed or launched.

## Hardware gate

Empty device-specific taps, active description mutation, actual preserved tap/aggregate IDs and absence of stop/create calls still need isolated Core Audio integration validation on supported macOS versions. If HAL does not retain valid empty-source formats/slots, startup or readiness fails protected; there is no silent fallback to the old rebuild-on-process-churn path.

The PID discovery race remains: the first sound of a newly launched process can precede its membership update, including briefly taking the remainder's gain. No test here measures direct original playback, first-sample protection, audible gaps or acoustic latency. The research's externally attenuated output-capture matrix remains a release gate.

macOS 26 bundle subscriptions and a virtual driver redesign were not added. Native helper-prefix/exclusion semantics need validation before replacing the existing matching policy; the existing driver cannot provide per-client pre-sum attenuation unchanged.
