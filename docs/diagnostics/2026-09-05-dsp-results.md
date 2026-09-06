# Audio quality implementation results

Implemented the research recommendations in the working tree. The installed app/helper and hardware routing/buffers were not changed. This report preserves the important evidence before the user-requested cleanup of temporary probes and isolated build caches.

## Implemented

- Replaced the block-cadence custom limiter with a preallocated Apple AUPeakLimiter wrapper: 1.5 ms attack/lookahead, 50 ms decay, zero pregain. Native input/output defenses handle nonfinite/corrupt samples, unexpected slice sizes and render failures without raw bypass.
- Native rendering is warmed with silence and reset before device I/O starts. Render failures are published atomically and enter existing bounded, guarded recovery.
- Removed the unused old envelope/ring implementation and superseded helper-only tests. New tests render the actual native wrapper across callback partitions.
- Added finite 5 ms normal gain ramps and one atomic publication for both stereo gain targets. Shared production input mixing is exercised with synthetic buffer lists.
- Null input buffers retain channel positions; mono feeds both sides and stereo-to-mono averages rather than doubling. Unsupported/non-Float32/non-mono-or-stereo formats are rejected instead of reinterpreted.
- Coalesced ordinary control targets while preserving topology barriers and guard ownership. Repeated failures now advance the documented capped recovery backoff.
- Unchanged topology no longer enters the hardware mute guard solely because health observations are not yet fresh; actual failures remain owned by the generation-bound recovery monitor.
- Exact device snapshots preserve independent volume elements and partial mute masks through rebuild, recovery, fades, ordinary controls, zero-to-raise, and exit. A common gain preserves channel ratios, capped by channel headroom.

## Why native was selected

Both candidates passed their fixed finite-signal criteria. Native reused the platform implementation and had lower standalone processing cost in the evaluated harness. This is a practical maintenance/performance choice, not proof of perceptual superiority or true-peak safety.

| Rendered native result | Observation |
| --- | --- |
| 44.1 / 48 / 96 kHz impulse delay | 66 / 72 / 144 samples |
| Below-ceiling impulse/sine delayed error | zero in evaluated fixtures |
| Stereo linkage error | at most about 7.5e-9 |
| Seeded variable-block difference | at most about 2.98e-8 |
| Finite sample-ceiling criterion | passed at <=1.00001 |
| NaN/infinity without wrapper | invalid sample passed through; wrapper sanitation required |
| Overload recovery, 48 kHz, input 2→0.1 | about 0.07236 at 50 ms, 0.08618 at 100 ms, 0.0999983 after 750 ms |

Native overload peaks have rate-dependent headroom (approximately 0.89–0.95 in the evaluated sustained/impulse/sine cases), so its reported decay setting is not a promise of complete gain recovery within 50 ms. The production wrapper additionally passed extreme finite-input recovery, quiet-sibling-channel, mono/interleaved, reset and oversized-slice checks.

The independently written finite minimum-hold/constrained-release/finite-smoothing comparator passed 893,253 assertions. It had the same 66/72/144-sample delay, exact partition invariance in its fixtures, and about 67 ns/stereo-frame median standalone throughput at 48 kHz. Its low-frequency overload modulation remained measurable. It was not added as a production dependency.

## Whole-mixer offline timing

A Release executable compiled the actual input mixer, gain ramps, atomics, DSP kernels and native wrapper. It exercised 1/8/16 stereo sources, 64/128/256/512-frame buffers, constant/moving targets, 1,000 warmup calls and 5,000 measured calls per case: 24 scenarios total.

All output checks were finite and within [-1,1], with no native render failure or final safety-guard intervention. Median elapsed processing occupied about 0.026–0.181% of nominal buffer duration; maximum observed p99 fraction was about 6.566%. There were also large 50–151 ms wall-time outliers in the ordinary-priority process. Their cause was not established, and these results do **not** prove real-time deadline compliance or dropout-free hardware playback. The timed region covered output clearing, input mixing/ramp/meter accumulation and native processing; HAL scheduling and the outer callback's diagnostics were not measured.

## Final verification

- `make test`: **102 package XCTest cases**, 2 opt-in hardware skips, zero failures; **53 Swift Testing cases**, passed; **49 App XCTest cases**, zero failures.
- `xcodebuild ... analyze`: succeeded.
- Independent DSP review: native failure-to-recovery and initialization warmup findings resolved; no remaining concrete blocker in the reviewed paths.
- Independent control review: exact primary exit restoration and calibration-preserving user-volume findings resolved.

The older limiter/ring helper tests were retired with their unused implementation. Native rendered-signal and shared mixer-path tests replace those checks; the changed total is not evidence of reduced coverage.

## Remaining limits

No install, commit, physical buffer tuning, live stable-tap membership experiment, acoustic loopback or listening/true-peak test was performed. Real topology changes still use the protected rebuild/fade path and can briefly interrupt playback. Native resource warmup reduces first-render risk but does not replace allocation instrumentation under the actual I/O thread. Mono/stereo Float32 is the supported DSP format envelope; other layouts require an intentional conversion policy.

Temporary standalone comparison harnesses, research scratch reports and isolated build/module caches were removed at the user's request after these results were recorded. Durable production tests remain in `BamKit/Tests/AudioEngineTests` and `AppTests`; historical reports referring to `/tmp/bam-*` describe the pre-cleanup evidence locations.
