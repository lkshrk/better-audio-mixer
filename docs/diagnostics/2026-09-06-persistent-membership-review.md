# Second independent review: persistent membership

Four fresh read-only subagents reviewed the uncommitted prototype: membership/recovery, hardware protection/concurrency, callback/rendering, and test adequacy. Parent validated and deduplicated findings. No implementation changes, hardware probes, installation or playback tests were performed. Existing passing tests do not cover the two scenarios below.

## P1 — Volume timeout can leave output audible while blocking attenuation

Location: `BamKit/Sources/AudioEngine/CoreAudioProperty.swift:23–32`; integration: `CoreAudioEngine.swift` `confirmedVolume` and `writeDeviceState`, `App/ConsoleViewModel+Volume.swift:424–440`.

An ordinary slider change uses `restoreOutputDeviceState(..., restoreVolume: true, restoreMute: false)` while hardware is already unmuted. If HAL accepts a higher volume request but confirmation fails, `HardwareWriteState` latches uncertainty. Subsequent lower/zero volume requests are rejected. The volume failure returns before any mute request, and the App handles only the successful result without surfacing the failure. The original delayed higher volume can therefore become audible while volume controls cannot reduce it.

This differs from intentionally keeping an already-muted device protected: this caller has not acquired hardware protection.

Fix: make the shared volume failure path request best-effort hardware mute after releasing the write-state lock, retain uncertainty, and surface the failure in the App. Do not claim the mute cancels the pending write.

Regression: begin unmuted; accept a higher scalar but time out; issue a lower/zero target. Assert a hardware mute request occurs, the lower request does not clear uncertainty, and the App exposes failure.

## P2 — Per-stream format is mistaken for the whole output layout

Location: `BamKit/Sources/AudioEngine/RouterAggregate.swift:126–136`; format acquisition: `:353–358`.

`kAudioDevicePropertyStreamFormat` returns one AudioStream's ASBD. A valid output with two mono Float32 streams has a mono first-stream format and two output buffers. The new `buffers.count == (planar ? channels : 1)` check requires one buffer and rejects every callback. The prior renderer explicitly handled two mono buffers as L/R. The outputs remain zero, readiness times out, and router startup fails.

Evidence: installed Core Audio SDK `AudioHardwareDeprecated.h:602–609` documents this property's per-stream scope, including devices with multiple streams. This is a contract/source finding, not a live-device reproduction.

Fix: obtain and freeze the actual output stream configuration and per-stream formats before IO starts; validate callbacks against that topology while preserving the supported two-mono-buffer path.

Regression: supply two mono output buffers with a mono first-stream ASBD. Existing tests use a two-channel noninterleaved ASBD and miss this distinction.

## Other outcomes

No additional concrete membership/gain-mapping, object-identity, atomic-ordering or lifetime defect survived review. A suspected output-switch reuse issue was eliminated by the preceding device-topology guard. Uncertain-tap recovery and unmeasured first-sample/acoustic behavior remain the previously documented prototype limitations.

Original review result: two findings, no source changes or Linear tickets.

## Follow-up fixes

Both findings were subsequently fixed at the user's request. P1 now invokes pinned all-channel mute after leaving the hardware-write lock, retains uncertainty and the latest requested volume, and exposes failure in the App. P2 now freezes the complete output buffer configuration and each stream's virtual format before IO. Both original reviewers rechecked their fixes and found no further actionable defects. Deterministic regression tests cover the reported triggers; full verification is recorded in the implementation report. No live playback has been attempted; physical trial setup is pending.
