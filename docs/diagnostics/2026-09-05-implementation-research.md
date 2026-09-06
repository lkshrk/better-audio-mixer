# Best practices and reference implementations for BAM

Research date: 2026-09-05. This extends the [quality/latency audit](2026-09-05-quality-latency-audit.md) of BAM commit `af8ea4c`. Three agents inspected actual source code, pinned revisions, and license files. The parent checked official real-time guidance and queried Apple's native limiter in an isolated process. No BAM source, installed app, audio route, volume, or hardware buffer setting was changed.

## Recommendation

**Keep BAM's single hardware-clocked aggregate. Test Apple's native peak limiter before maintaining more custom DSP; use Signalsmith's finite, delay-aligned envelope as the strongest open-source limiter reference if the native unit does not meet the requirements.**

Use sample-counted ramps for normal gains, bounded/latest-value control handoff, and explicit lifecycle ordering. Do not copy an entire capture app or driver architecture. None of the inspected projects proves lower measured end-to-end latency than BAM or makes BAM's hardware mute guard unnecessary.

## What the projects actually do

| Reference | Inspected design | Useful for BAM | What not to assume/copy |
| --- | --- | --- | --- |
| AudioCap | Process tap plus physical-main aggregate; tap drift correction enabled | Tap/aggregate setup and ownership | Its IO block writes an audio file; it is a capture sample, not ideal render-thread practice |
| AudioTee | Tap capture, preallocated ring, chunked stdout | Bounded memory and chunk accounting | Default 200 ms chunks and synchronous stdout writes are unsuitable for live playback |
| OBS Studio | Inspected macOS desktop capture uses ScreenCaptureKit; device capture uses AUHAL | Timestamp preservation | It is not evidence for safe gapless process-tap rerouting |
| BackgroundMusic | Per-client driver processing; separate IOProcs bridged with timestamped CARingBuffer | Device lifecycle ordering, nonblocking recovery, explicit discontinuities | Its driver architecture, blockwise gain and hard clipping are not automatically better than BAM |
| BlackHole | Fixed, timestamp-addressed loopback ring | Small bounded buffer path, stale-data clearing | “Zero additional latency” is not a measured app-to-speaker latency result |
| eqMac public code | Separate processing/output engines, circular buffer, varispeed drift controller | Clock/headroom tradeoffs | Public source is explicitly old v1.3.2 without Pro; current per-app mixer is not publicly inspectable there |
| Signalsmith basics | Finite minimum-hold, constrained release, finite smoothing, matched audio delay | Strong reference for correct lookahead scheduling | Not proof of every parameter transition or true-peak behavior |
| FFmpeg alimiter | Delay ring, queued peak positions, attenuation slopes | Peak timing and channel-linked gain | Do not put the allocating filter framework in the IOProc or mistake timeline compensation for removed live delay |
| JUCE | Sample-counted smoothing; limiter uses two compressors and clipping | Gain-ramp mechanics | Its limiter is not a transparent linked-stereo lookahead/true-peak design |

### Capture projects: useful examples, different goals

AudioCap sets a physical main subdevice and enables tap drift compensation. Its recording block wraps input and writes `AVAudioFile` during the IO callback. Use its setup as a comparison, not as a rule that callback file I/O is acceptable for BAM. [Setup](https://github.com/insidegui/AudioCap/blob/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3/AudioCap/ProcessTap/ProcessTap.swift#L89-L158), [recording callback](https://github.com/insidegui/AudioCap/blob/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3/AudioCap/ProcessTap/ProcessTap.swift#L223-L238).

AudioTee preallocates ring/scratch storage, but processes complete chunks and invokes its output handler synchronously. That handler loops on stdout writes. A slow reader can block capture despite the bounded ring. Its default chunk duration is batching, not a HAL buffer-size recommendation. [Recorder](https://github.com/makeusabrew/audiotee/blob/56ac954369a09318e46b88a6eec33c2d2b0d32a3/Sources/AudioTeeCore/Core/AudioRecorder.swift#L81-L154), [stdout handler](https://github.com/makeusabrew/audiotee/blob/56ac954369a09318e46b88a6eec33c2d2b0d32a3/Sources/AudioTeeCLI/BinaryOutputHandler.swift#L9-L20).

OBS's inspected macOS desktop/application path creates an `SCStream`; settings updates destroy/recreate it. It preserves capture timestamps, but neither that queueing model nor its stream queue depth defines BAM playback latency. [Capture implementation](https://github.com/obsproject/obs-studio/blob/6b3e550729f125b6c5b3767df88c08f5aef9d264/plugins/mac-capture/mac-sck-audio-capture.m#L57-L169), [timestamp delivery](https://github.com/obsproject/obs-studio/blob/6b3e550729f125b6c5b3767df88c08f5aef9d264/plugins/mac-capture/mac-sck-common.m#L324-L351).

### Routers/drivers: borrow invariants, not whole architectures

BackgroundMusic processes per-client volume before clients are mixed. Its separate physical-output playthrough need not be reconstructed merely because another client appears. During device switching, it deactivates playthrough so notifications cannot restart audio during control synchronization. This is a valuable invariant for BAM's guard ownership. [Per-client path](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMDriver/BGMDriver/BGM_Device.cpp#L1607-L1651), [switch ordering](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMAudioDeviceManager.mm#L282-L335).

Its ring is allocated outside rendering at 20 output-buffer capacity. Output uses a try-lock/silence path and resynchronizes invalid read offsets. Transfer bounded storage, explicit discontinuity handling, and avoiding waits on control work—not the capacity multiplier as a latency target. Ring capacity is not occupancy. Its inspected driver gain path is blockwise with clipping, so it is not the preferred smoothing/limiter reference. [Allocation](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMPlayThrough.cpp#L184-L209), [output/recovery](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMPlayThrough.cpp#L934-L1000).

BlackHole's configured extra latency defaults to zero, but samples still pass through Core Audio scheduling, ring storage, and output hardware. Its processing clears stale audio and recommends a larger I/O buffer when deadlines are missed. A driver rewrite is not justified by its latency slogan. [Default](https://github.com/ExistentialAudio/BlackHole/blob/ffcb74433fbcf8c8ca5c736677c1a4864384dc09/BlackHole/BlackHole.c#L235-L237), [processing](https://github.com/ExistentialAudio/BlackHole/blob/ffcb74433fbcf8c8ca5c736677c1a4864384dc09/BlackHole/BlackHole.c#L4520-L4603).

Public eqMac code illustrates the cost of separate clock domains: its output offset includes safety offsets and both I/O buffers; a controller adjusts varispeed from buffer headroom. This can be appropriate when bridging independent devices, but introduces buffering, rate adjustment, and more recovery state. Preserve BAM's simpler path unless measurements require such a bridge. [Output/drift logic](https://github.com/bitgapp/eqMac/blob/04e5a3a9bd3a65f2b5105cf54a76d2c72a1d00d7/native/app/Source/Audio/Outputs/Output.swift#L138-L215). The repository explicitly limits public source to v1.3.2 without Pro, so it does not establish how current eqMac's per-app mixer works. [Scope statement](https://github.com/bitgapp/eqMac/blob/04e5a3a9bd3a65f2b5105cf54a76d2c72a1d00d7/README.md#L13).

## Limiter choices

### First candidate: Apple's AUPeakLimiter

Apple provides a system effect for peak limiting and exposes its processing-latency property. This is the smallest dependency choice, but its availability does not prove it meets BAM's transparency, stereo behavior, or peak requirements. [Peak limiter](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_peaklimiter), [latency property](https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_latency).

An isolated local metadata query configured 48 kHz noninterleaved stereo:

| Requested/accepted attack | Reported AU processing latency |
| ---: | ---: |
| 1 ms | approximately 1 ms |
| 1.5 ms | approximately 1.5 ms |
| 12 ms | approximately 12 ms |

All property/initialization calls succeeded for those planar configurations. The first interleaved Float32 setup returned `-10868`, so integration must negotiate format rather than assuming a drop-in buffer layout. The SDK documents attack parameters from 1–30 ms with a 12 ms default: leaving defaults is not equivalent to BAM's current 1.5 ms design.

**This query rendered no audio.** Reported latency is not measured impulse delay, total device latency, or a ceiling/transparency benchmark. Before choosing the unit, run the same overload, stereo, partition, impulse-delay, distortion, and callback-cost checks as the custom candidate. Initialize/allocate/configure outside the IOProc; use preallocated layout adaptation if required. Local query source: `/tmp/bam-native-limiter-info.swift`.

### Strongest open-source algorithm reference: Signalsmith

Signalsmith's limiter constrains required gain using a moving minimum, a release envelope that cannot exceed the constraint, and finite smoothing. The hold support includes the attack window, and audio is delayed to align with the resulting gain. This addresses BAM's actual defect: applying a current-block envelope to differently delayed peaks. [Gain-envelope code](https://github.com/Signalsmith-Audio/basics/blob/7e95f44afa19e4d6cc372bd1863a49aebe45e748/include/signalsmith-basics/limiter.h#L67-L95), [sample timing/channel linking](https://github.com/Signalsmith-Audio/basics/blob/7e95f44afa19e4d6cc372bd1863a49aebe45e748/include/signalsmith-basics/limiter.h#L121-L193).

The author's explanation distinguishes finite envelope support from an asymptotic IIR attack and discusses the latency/distortion compromise. Use full stereo linking for BAM initially, fixed lookahead while playing, and state that survives callback boundaries. The reference's configurable linking/delay transitions deserve separate tests; this is not a blanket proof of every mode. [Design explanation](https://signalsmith-audio.co.uk/writing/2022/limiter/).

If Apple's unit fails the acceptance criteria, a small adaptation of this bounded design is a better starting point than adjusting BAM's current coefficient once per buffer. Do not confuse sample-peak containment with true-peak protection.

### Useful alternatives, different tradeoffs

FFmpeg `alimiter` tracks peaks in a delay ring and advances attenuation slopes per audio frame. It links gain across channels and schedules around buffered peaks. It also clips before optional normalization/output gain, so the final ceiling depends on those settings. The filter framework can allocate frames/metadata during processing; it should not be imported wholesale into BAM's callback. Its latency option handles buffered samples on a timeline—it cannot remove the real-time wait for lookahead. [Source](https://github.com/FFmpeg/FFmpeg/blob/9997fd060680d427bcc0c0715d163346da7ebd6f/libavfilter/af_alimiter.c), [official filter documentation](https://ffmpeg.org/ffmpeg-filters.html#alimiter).

JUCE's limiter combines two compressor stages, smoothed makeup gain, and final clipping. It has no lookahead and uses per-channel envelope state. It is a useful example of the zero-lookahead/distortion tradeoff, not the preferred template for transparent linked-stereo limiting. [Limiter configuration](https://github.com/juce-framework/JUCE/blob/078b1cd6110e974698dbb4c7e5151d16b08dde9b/modules/juce_dsp/widgets/juce_Limiter.cpp), [processing/clipping](https://github.com/juce-framework/JUCE/blob/078b1cd6110e974698dbb4c7e5151d16b08dde9b/modules/juce_dsp/widgets/juce_Limiter.h).

JUCE's `SmoothedValue` is a better reference for BAM's ordinary controls: convert duration to sample count, retarget from the current value, advance once per frame, use that same value across channels, and reach the target exactly. A finite linear ramp can reach mute; multiplicative smoothing cannot reach zero. This is a small algorithm BAM can implement independently without adding JUCE. [Ramp implementation](https://github.com/juce-framework/JUCE/blob/078b1cd6110e974698dbb4c7e5151d16b08dde9b/modules/juce_audio_basics/utilities/juce_SmoothedValue.h#L264-L325), [multichannel application](https://github.com/juce-framework/JUCE/blob/078b1cd6110e974698dbb4c7e5151d16b08dde9b/modules/juce_audio_basics/utilities/juce_SmoothedValue.h#L135-L157).

## Best practices to apply to BAM

1. **Bound callback work.** Preallocate buffers/state, avoid blocking I/O, locks/waits and memory allocation in processing, and publish lightweight telemetry for another thread to consume. PortAudio's callback guidance explicitly warns against operations with unpredictable completion time. The examples above demonstrate why being open source does not automatically mean every callback follows those rules. [Callback guidance](https://files.portaudio.com/docs/v19-doxydocs/writing_a_callback.html).
2. **Use the existing real-time thread first.** A second pipeline/thread needs a demonstrated benefit and correct workgroup/clock handling. Apple's workgroup guidance is especially relevant when creating additional real-time threads, not an instruction to add them. [Apple Audio Workgroups](https://developer.apple.com/videos/play/wwdc2020/10224/).
3. **Separate topology from targets.** Serialize device/tap mutations and guard ownership, while coalescing ordinary gain targets. Advance DSP smoothing in samples, not sleeping UI tasks or callback-count approximations. Keep emergency routing protection separate from normal gain ramps.
4. **Respect HAL buffer structure even for silence.** Apple's IOProc contract permits disabled streams with null data but retained buffer size. Preserve channel positions when skipping unreadable data; do not shift later sources' gains. This strengthens the earlier BAM nil-buffer concern from a hypothetical input shape to an API-documented possibility, although it was not observed in the running app. [IOProc contract](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc); also verified in installed `AudioHardware.h`.
5. **Retain stable topology where possible, with guarded fallback.** Apple supports tap-description updates and, on macOS 26, restored process membership by bundle ID. None of the inspected project code guarantees gap-free, mute-continuous updates. Test these APIs rather than replacing fixed-UID guarded rebuilds on assumption. [Description property](https://developer.apple.com/documentation/coreaudio/kaudiotappropertydescription), [process restoration](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled).
6. **Measure latency in the correct domain.** Buffer capacity, buffer duration, algorithmic delay, advertised latency and acoustic loopback are different quantities. Record the actual accepted frame size and timestamp validity, then measure BAM-on minus BAM-off with the same device/rate. Smaller buffers reduce scheduling budget; choose the smallest stable result under load. [PortAudio latency definitions](https://github.com/PortAudio/portaudio/wiki/BufferingLatencyAndTimingImplementationGuidelines), [Apple buffer/latency discussion](https://developer.apple.com/library/archive/technotes/tn2321/_index.html).

## Selection and validation sequence

1. Build an offline comparison of current DSP, Apple AUPeakLimiter, and the bounded Signalsmith-style candidate. Start near the existing 1.5 ms delay so the comparison is meaningful; do not declare that delay optimal.
2. Require peak containment, exact impulse delay, block-partition invariance, linked-stereo behavior, release timing, silence/recovery, and finite handling of invalid samples. Test 44.1/48/96 kHz and random block partitions. Measure distortion and intersample peaks separately.
3. Select the smallest implementation that passes. Native first is a maintenance preference, not evidence it wins the signal tests. Keep final emergency clipping observable rather than letting it conceal a defective envelope.
4. Add ordinary gain ramps and latest-target control handoff. Preserve precise per-channel hardware snapshots when a device lacks main controls.
5. Fix unchanged-event/recovery policy, then prototype stable tap membership with the existing hardware mute fallback.
6. Only then compare supported physical buffer sizes, such as 512/256/128 frames, using loopback plus dropout/deadline stress tests. Do not sell nominal frame duration as total audible latency.

No inspected reference justifies removing the full-volume mute guard, forcing a higher sample rate, unconditionally disabling drift correction, or rewriting BAM around a virtual driver.

## Revision and license record

These are inspected source revisions, not a claim that every released product uses this exact code. BAM's root license is MIT; references have different terms. No external source was copied into BAM during this research.

| Project | Pinned revision | Verified licensing/scope |
| --- | --- | --- |
| AudioCap | `6f609e8ad1b1e11fa0e8edbe91864cb099f00de3` | [BSD-2-Clause](https://github.com/insidegui/AudioCap/blob/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3/LICENSE) |
| AudioTee | `56ac954369a09318e46b88a6eec33c2d2b0d32a3` | [README declares MIT](https://github.com/makeusabrew/audiotee/blob/56ac954369a09318e46b88a6eec33c2d2b0d32a3/README.md#L175-L179); inspected tree lacks a full LICENSE/COPYING file |
| OBS | `6b3e550729f125b6c5b3767df88c08f5aef9d264` | [GPL-2.0-or-later project](https://github.com/obsproject/obs-studio/blob/6b3e550729f125b6c5b3767df88c08f5aef9d264/README.rst#L22-L23) |
| BackgroundMusic | `8c25450e9b0d3867417c4872018b03fb30c0c85c` | [GPL-2.0-or-later headers](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMDeviceControlSync.cpp#L1-L14); bundled Apple utilities have separate notices |
| BlackHole | `ffcb74433fbcf8c8ca5c736677c1a4864384dc09` | [GPL-3.0 source](https://github.com/ExistentialAudio/BlackHole/blob/ffcb74433fbcf8c8ca5c736677c1a4864384dc09/LICENSE); official binaries/branding have additional notices |
| eqMac | `04e5a3a9bd3a65f2b5105cf54a76d2c72a1d00d7` | [Apache-2.0 root](https://github.com/bitgapp/eqMac/blob/04e5a3a9bd3a65f2b5105cf54a76d2c72a1d00d7/LICENSE); old public v1.3.2, no Pro |
| Signalsmith basics | `7e95f44afa19e4d6cc372bd1863a49aebe45e748` | [MIT](https://github.com/Signalsmith-Audio/basics/blob/7e95f44afa19e4d6cc372bd1863a49aebe45e748/LICENSE.txt); preserve notices for any included components |
| FFmpeg | `9997fd060680d427bcc0c0715d163346da7ebd6f` | [Inspected alimiter source: LGPL-2.1-or-later](https://github.com/FFmpeg/FFmpeg/blob/9997fd060680d427bcc0c0715d163346da7ebd6f/libavfilter/af_alimiter.c) |
| JUCE | `078b1cd6110e974698dbb4c7e5151d16b08dde9b` | [Inspected headers offer JUCE licensing or AGPLv3](https://github.com/juce-framework/JUCE/blob/078b1cd6110e974698dbb4c7e5151d16b08dde9b/modules/juce_dsp/widgets/juce_Limiter.h) |

Treat algorithm understanding separately from copying/translating implementation or adding a dependency; any reuse must retain the applicable license/notice requirements. Proprietary product internals and unmeasured latency/quality claims were not used as evidence.
