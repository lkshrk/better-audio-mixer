# Is this the best approach for audio quality and low latency?

**No—not yet. Keep the core audio architecture, but correct the DSP and improve transition/control policy before calling it optimized.**

This is a deeper review of commit `af8ea4c0402c31c5e9be090ac52e8b47b5337f9a`. Three independent agents audited the sample path, lifecycle design, and Apple API contracts. The parent verified key source locations, checked historical attribution, and queried hardware timing properties without changing them. No application source was modified or installed during this audit.

The recent changes fix real memory retention and improve protection against unattenuated playback during routing changes. They do not establish best signal quality or minimum end-to-end latency. In particular, a previously existing limiter defect escaped the earlier unit tests because those tests exercised its mathematical helper at a different cadence from the actual audio callback.

## 1. Most important finding: the limiter does not reliably limit

**Confirmed by source and a bounded offline reproduction. High priority.**

`AudioLimiter.swift:18-22` computes per-sample exponential coefficients. `RouterAggregate.swift:261-264` selects nominal 1 ms attack and 100 ms release. However, the callback invokes `nextEnvelope` only once per entire buffer (`RouterAggregate.swift:449-451`), then applies one constant gain to that delayed buffer.

For a buffer of B frames, the effective time constants become B times longer:

| Callback frames at 48 kHz | Effective attack | Effective release |
| ---: | ---: | ---: |
| 64 | 64 ms | 6.4 s |
| 128 | 128 ms | 12.8 s |
| 256 | 256 ms | 25.6 s |
| 512 | 512 ms | 51.2 s |
| 1024 | 1.024 s | 102.4 s |

The probe links the actual production `AudioLimiter.swift` and `DSPKernels.swift` and mirrors the callback's block-peak → envelope → delay → constant-gain sequence. It does not execute a live HAL callback. With 48 kHz / 512-frame blocks, after the startup fade:

- Input amplitude **2.0** initially produces output peak **1.97938**, despite a configured ceiling of **1.0**.
- After one second of overload, output remains **1.14109**.
- Five seconds after switching input to **0.5**, output is still around **0.30526**, rather than having recovered on the intended 100 ms scale.

Those samples exceed the configured ceiling; actual downstream clipping depends on the device/conversion path. The important proven result is that the limiter does not enforce its own limit, and behavior changes substantially with callback size.

There is a second, independent timing error. A peak near a buffer boundary can remain in the 72-frame delay while the next buffer begins releasing gain. Even an instantaneous block attack still produced **1.0002084** for the boundary-impulse probe. Merely exponentiating coefficients by the block length, or calling the same attack smoother per sample, is not sufficient to prove lookahead peak containment.

**Recommended approach:** retain a small fixed lookahead, but schedule stereo-linked gain against the actual delayed sample/window positions. Separate peak containment from release smoothing. Make the production callback use the same small processing routine that offline tests exercise. Require:

- equivalent output when the same signal is split into different callback sizes;
- impulses at every delay and block-boundary position;
- sustained overload, bursts, and correct recovery time;
- below-ceiling transparency apart from the known delay;
- mono/planar/interleaved consistency and no allocations in processing.

Decide whether the product needs sample-peak or true-peak limiting. Current sample maxima do not establish intersample/true-peak protection. Do not add oversampling or a DSP dependency without that requirement and measurements.

**Keep the hardware mute guard.** A correct limiter cannot protect playback that bypasses BAM when capture stops.

## 2. Keep the direct aggregate path; improve normal gain changes

The steady path is:

```text
Process taps → aggregate IOProc → per-source gains + sum
             → startup ramp → lookahead limiter → hardware
```

The shared callback, preallocated scratch/ring storage, vectorized mixing, and atomic control targets are a good starting point. There is no reason from this evidence to add an application-level audio queue, another clock domain, or a wholesale C/C++ rewrite. Apple's tap model also uses aggregate devices to consume tap audio; that supports this general shape, not a claim of optimal measured latency. [Apple's tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

**Ordinary gain changes are not smoothed.** `RouterAggregate.setGain` writes L/R atomics, and the callback uses a fixed gain per channel for the whole block. The initial 2048-frame fade does not smooth later volume, pan, solo, or mute changes. A discontinuous gain change can create a click or zipper noise. Separate L/R stores can also briefly expose different update versions.

Use short, sample-rate-aware ramps for normal gain targets, preserving prompt emergency mute behavior. This changes control response slightly; it need not add an audio delay buffer. Test discontinuity bounds and response time, including linked stereo changes. Float32 summation itself is not the first thing to replace.

Additional conditional concerns deserve targeted fixtures, not immediate architecture changes:

- `RouterAggregate.swift:336` skips a nil-data input buffer before advancing its channel offset at line 378. If HAL supplies such a buffer with a nonzero channel count, subsequent data can map to the wrong source gain. Test a synthetic buffer list; the triggering HAL condition was not observed live.
- Mono channels map left and multichannel inputs fold by even/odd channel parity. That is not a deliberate surround downmix policy.
- `ProcessTap` records the format, but the callback assumes Float32 storage. Explicitly validate the supported format/layout or implement the required conversion; do not claim arbitrary-device/surround fidelity.
- Tap drift correction is explicitly disabled at `RouterAggregate.swift:185`, while capture and render devices can differ. A single aggregate does not prove all participating sources share a hardware clock. Apple documents drift correction/resampling for unsynchronized aggregate members; validate the specific tap clock relationship and long-duration behavior before changing the setting. [Apple aggregate settings](https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac).

There are potential callback cost reductions—moving meter logarithms off the audio thread, avoiding a completed startup-ramp scan—but they rank below the signal defects. No callback deadline profile currently demonstrates that these are bottlenecks. Apple emphasizes completing real-time processing within the device's deadline; extra real-time threads/workgroup management are not automatically beneficial. [Audio Workgroups](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups), [Apple real-time processing guidance](https://developer.apple.com/videos/play/wwdc2024/10211/).

## 3. Separate three different meanings of “lag”

| Dimension | Current evidence | Appropriate optimization |
| --- | --- | --- |
| Steady audio transport delay | ~1.5 ms explicit DSP lookahead, plus unmeasured tap/HAL/device stages | Measure loopback, then tune buffer/clock/DSP choices |
| Control response | Gains/volume can wait behind a 24 × 50 ms hardware fade and older queued changes | Coalesce target state; keep only structural operations in strict FIFO |
| Launch/exit interruptions | Guarded shared-aggregate rebuild and startup fade | Avoid unnecessary mutations; investigate stable tap membership |

The 2048-frame startup ramp is about **42.67 ms at 48 kHz**. It is a transient amplitude recovery, not 42.67 ms of ongoing audio transport delay. Similarly, the ~1.2 s hardware fade delays controls/transition completion; it does not mean every audio sample is delayed by 1.2 s.

### Read-only hardware observations on this Mac

Physical outputs reported 48 kHz and 512-frame buffers during this audit. One such buffer lasts **10.67 ms**. The queried frame-size range was 15–4096; it is a reported API range, not proof that every value is stable or useful.

| Output | Buffer frames | Device output latency, frames | Safety offset, frames | Stream latency, frames |
| --- | ---: | ---: | ---: | ---: |
| Razer BlackShark V2 Pro 2.4 | 512 | 50 | 50 | 0 |
| Odyssey G60SD, system default | 512 | 88 | 320 | 0 |
| Mac mini Speakers | 512 | 60 | 48 | 183 |

These are HAL-reported values, not acoustic measurements. The private BAM aggregate was not visible to the separate inventory process, so **its actual callback size is unknown**. Nor do these values measure wireless transport, acoustic output, or establish that the installed app is running this committed code. Do not simply sum every aggregate and physical-device number; that can count a shared stage twice.

At 48 kHz, 256 frames lasts 5.33 ms and 128 lasts 2.67 ms. Treat those as candidate buffer durations to test, not promised end-to-end results. Apple documents the buffer/latency tradeoff; the right target is the smallest **stable** accepted buffer with adequate callback deadline margin. [Apple TN2321](https://developer.apple.com/library/archive/technotes/tn2321/_index.html).

Measure physical loopback with BAM off and on using the same output, sample rate, and source. The difference is much more useful than choosing a buffer from a table. Measure steady delay, jitter, missing samples, and transition peaks separately. A higher sample rate or disabled drift correction is not automatically better quality or lower stable latency.

## 4. The new control/safety policy can be improved

### Health uncertainty should not automatically mute unchanged topology

The new no-op check requires a recent clean health observation. The first observation follows a three-second startup wait, and subsequent checks run every two seconds. `startRouter` also clears `lastHealthyObservation` before discovering that an existing aggregate can be reused. Thus initial, stale, or clustered health states can still turn unchanged topology events into hardware mute cycles. Frequent guarded activity suspends health sampling and can extend that window.

A better decision separates:

1. **Unchanged topology, no evidence requiring recovery:** no structural/audio mutation; update/defer health assessment.
2. **Changed topology:** guarded mutation.
3. **Actual failure:** guarded, bounded recovery.

Unknown health must not be mistaken for proven health, but it also need not immediately trigger destructive action. Preserve the current guard whenever recovery or structural work actually happens. Add tests for unchanged events before the first health sample and after a guarded no-op; current happy-path no-op tests are not enough.

### Do not replay stale controls behind a long fade

The queue now serializes topology, gains, output-volume updates, and the hardware fade. It correctly avoids dangerous overlap, but rapid slider changes can accumulate obsolete values behind at least 1.2 seconds of ramp work. Latest intent handling during a fade helps, yet does not remove that FIFO backlog.

Keep topology and guard ownership serialized. Make nonstructural gain/volume intent replaceable and consume the latest value at an appropriate safe boundary. Don't allow a UI optimization to bypass protection or unmute an unsafe route. Measure time from input event to audible gain response and the number of stale writes.

### Fix repeated-failure backoff

The App heartbeat says it uses 2→4→8→16→30-second delays. However, every status fold calls `scheduleRouterRecovery`, which cancels/recreates the heartbeat at two seconds. Repeated failures therefore reset the schedule instead of advancing it. This is **preexisting**, not introduced by `af8ea4c`.

Keep the existing heartbeat when the cause is unchanged; reset it on meaningful cause/lifecycle changes. Test repeated failures and intervals, not just one failure followed by success. This affects recovery work and interruption frequency, not steady-state sample latency.

### Preserve actual per-channel hardware state

When a device lacks a main volume element, `deviceVolume` averages L/R into one scalar. Restoration writes that scalar back to all supported output channels. On a device with L=0.2/R=0.8, a rebuild can restore both to 0.5, losing balance/calibration. Channels beyond L/R were not included in the snapshot at all.

The scalar L/R loss predates the commit; the checked setter now covers every output channel, so the limitation remains relevant to the revised safety path. Preserve per-element values for devices without a main control, including per-channel mute if applicable. This is conditional on hardware controls, not a claim that the user's current headset is affected. Keep the user-facing master scalar separate from the exact hardware snapshot used for restoration.

## 5. Stable taps are worth testing, not assuming

Today a grouped process starting/stopping changes the source's PID signature and often the remainder exclusion list. That changes tap identity and rebuilds the shared aggregate, interrupting other sources too. A no-op optimization cannot remove a real topology change.

Apple's installed SDK explicitly supports updating an existing tap through `kAudioTapPropertyDescription`. That creates a plausible experiment: retain tap/aggregate identity and update membership. **The API does not promise atomic, gap-free updates or uninterrupted mute protection.** [Tap description property](https://developer.apple.com/documentation/coreaudio/kaudiotappropertydescription).

On macOS 26, `CATapDescription.bundleIDs` and `processRestoreEnabled` may reduce manual PID churn. BAM's minimum OS is older, so this would need availability checks and an older-OS fallback. Test helpers, exclusions, first launch/relaunch, and callback continuity before adopting it. [bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids), [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription).

The full-volume concern is real: `CATapMutedWhenTapped` allows direct hardware playback when the tap is no longer being read. Changing tap mute mode or destroying a tap can change that protection; neither a limiter nor an update API makes overlapping/rebuilt routes automatically safe. Retain guarded fallback and the fixed-UID constraints until an alternative passes peak and continuity tests. [Apple tap mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior).

## Recommended order

| Priority | Work | Reason |
| --- | --- | --- |
| 1 | Correct limiter timing/window alignment and test the production processing path | Proven signal defect; existing 1.5 ms delay currently does not buy correct limiting |
| 2 | Smooth normal gains; preserve per-channel hardware restoration | Avoid clicks and calibration loss |
| 3 | Separate topology decisions from health assessment; coalesce controls; correct backoff | Remove unnecessary interruptions and perceived lag while retaining safety |
| 4 | Measure actual callback timing and BAM-on/off loopback; test 512→256→128 frames | Choose a supported low-latency setting with evidence of stability |
| 5 | Prototype stable tap membership with guarded fallback | Potentially remove whole-output interruptions on real app churn |

Acceptance should include sample-peak bounds, block-partition invariance, gain step behavior, channel preservation, measured steady latency and control latency, callback deadline margin under load, and P50/P95/P99 interruption duration during launches/exits. There is no evidence-based universal buffer size or claim of “best possible” quality yet.

## Evidence and limitations

- Earlier full tests/analyzer passed, but did not validate callback-level limiter scheduling, physical end-to-end delay, or audible peak behavior. Those results should not be presented as proof of optimal quality.
- The limiter scheduling and startup/gain code were not changed by the memory/safety commit. Some control latency/health conservatism is a tradeoff of that new implementation; the heartbeat and scalar snapshot issues were inherited.
- Offline DSP probe: `/tmp/bam-dsp-probe/main.swift`, linked against production helpers. Detailed agent evidence: `/tmp/bam-dsp-quality-audit.md`.
- Read-only timing inventory: `/tmp/bam-audio-timing.swift`. No buffer, rate, volume, default device, or tap was changed.
- Apple API claims were checked against official documentation and installed SDK headers (`AudioHardware.h`, `AudioHardwareBase.h`, `CATapDescription.h`). Neither those references nor source inspection substitutes for hardware validation.
- Main graph coverage was checked; partial listener ranges were read directly. No DSP/control fixes were made during this analysis.
