# Measurement and reproducibility implementation

Status: implemented and locally verified; not installed or pushed. Physical latency remains unmeasured pending a suitable simultaneous reference/output recording.

User authorized proceeding with the improvement priorities. The first objective is usable evidence: callback processing budgets, limiter guards/failures, aggregate build duration, and an offline analysis path for simultaneous reference/output recordings. Do not label a nominal-budget miss as a measured acoustic dropout.

Ownership: implement_audio_diagnostics owns engine/model/protocol telemetry; parent owns App diagnostics and read-only control-socket exposure; latency_analysis_tool owns the stdlib WAV analyzer and self-check; implement_reproducible_builds owns lockfiles, Elgato CLI pin and workflow enforcement.

Constraints: no blocking/logging/allocation in callback instrumentation; use preallocated counters and monotonic ticks, format/report outside I/O; preserve mute/teardown protections. No device buffers, routing, or live taps change during implementation. Real loopback awaits the user's recording-path information. Stable live tap membership changes remain an experiment after measurements identify remaining transition costs.

Verification: synthetic timing/counter edge cases, App/control snapshot round trips, deterministic WAV delay/noise/silence/ambiguity checks, workflow validation and pinned resolution, followed by full package/App tests and static analysis. Reuse existing build caches and remove temporary helper tooling.

## Delivered

- `AudioDiagnostics` plus preallocated callback counters: last/mean/max processing time and nominal-budget ratios, valid frame ranges, over-budget observations, estimated output-host-time misses, and separate limiter input/guard/failure counts.
- Engine aggregate start counts/durations and retained prior-generation snapshot after closure. Durations exclude the complete protected mute/fade transition.
- App diagnostic report and handshake-protected, read-only `diagnostics` control message. No extra telemetry is added to the high-frequency meter frames.
- `scripts/collect-audio-diagnostics.py`: bounded JSONL collection, drains existing meter traffic between requests, no automatic app launch or audio setting changes.
- `scripts/analyze-audio-latency.py`: stdlib-only stereo PCM correlation estimate and matched BAM-off/on comparison; explicit inconclusive/ambiguous handling and self-tests. See [capture and collection guide](latency-measurement.md).
- Targeted SwiftPM/Xcode lockfiles, forced resolved versions in validation/release workflows, and Elgato CLI pinned to 1.9.0. Historical tags without lockfiles fail before signing instead of silently resolving different versions.

## Verification results

- Final strict-resolution `make test`: 119 package XCTest cases (2 opt-in hardware skips), 53 Swift Testing cases, 49 App XCTest cases; zero failures.
- WAV analyzer self-test passed PCM16/24/32, delay/noise/gain/polarity, comparison, silence, periodic ambiguity, unrelated signal, boundaries and format/rate validation.
- Collector: 5 tests passed, including deadline/buffer limits and continued meter draining with a small sender buffer.
- Xcode static analysis passed; final Release build passed.
- Actionlint syntax validation passed. Full ShellCheck retains 15 preexisting workflow warnings; no new warning was introduced by the pinning changes.
- Pinned Elgato CLI 1.9.0 successfully validated the plugin bundle.
- Both lockfiles resolve exactly Swift Atomics 1.3.1 and Yams 6.2.2; forced resolution was verified with SwiftPM and Xcode.
- Independent measurement review found no substantive RT/estimator fault. Parent additionally fixed collector backpressure between requests and explicit async actor dispatch, with regressions.

## Interpretation and remaining work

Callback snapshots are field-wise approximate, cover valid processed output callbacks, and exclude the final publication cost. Host-time misses are estimates, not certified underruns. An idle snapshot with zero callbacks is not a measured zero latency. Limiter input events are not a direct measurement of its complete gain-reduction envelope.

The correlation margin is heuristic and compares a bounded candidate shortlist. No acoustic delay, subjective quality, allocation-free runtime guarantee, or stable-tap continuity claim follows from these tests. Real headset capture still needs the recording-path choice requested from the user. Device-buffer tuning and live tap-membership experiments were not enabled.

The CLI pin does not freeze its transitive npm dependencies or remote validation schemas, and hosted CI has not run. These new changes remain in the working tree; the currently installed app needs an update before it can serve the new diagnostics endpoint. No large scratch build tree was created; the temporary npm validation cache is removed after checks.
