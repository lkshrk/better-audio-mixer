# Installed playback test — 2026-09-06

Installed the locally tested Release build, signed with the existing Developer ID. Source-product and installed executable SHA-256 both equal `a807c99bb2a98f2694928611d32688135454a458ebd21bacf1175b822d8b345e`. Installed process: PID 90314.

Previous installed bundle and preferences preserved at `.build-dev/install-tested-backup.nawCsr`. Existing original backup also retained. Installation confirmed master mute, lowered volume, verified hardware protection, replaced the old process without invoking its stock-volume exit handler, and verified the new engine before unmuting. Razer remains selected; playback enabled at approximately 12% (hardware readback 0.121502034). Prior master setting was 100%; it was deliberately not restored for this listening test.

## Live test results

90 snapshots over 89.36 seconds, including three Calculator open/close cycles:

- Engine running in every snapshot; generation remained 1 and aggregate build attempts remained 1. Ordinary Calculator lifecycle events caused no aggregate rebuild.
- Zero reported limiter render failures, guarded samples, nominal callback budget overruns, or estimated output-host-time misses.
- 48 kHz, 512-frame buffers: nominal buffer duration 10.67 ms.
- Maximum observed processing time 0.1022 ms, approximately 0.96% of nominal buffer budget. Mean processing time 0.0333 ms.
- Limiter delay 72 frames (1.5 ms); this is not end-to-end acoustic latency.
- Startup aggregate creation took approximately 1969 ms; this startup metric is not a measured application-transition gap.

Independent log/process check: new bam physical footprint 37 MB (peak 38 MB) after 2m24s; existing BAMStreamDeck physical footprint 11 MB (peak 12 MB) after approximately 9h56m. Startup logs confirmed five live taps and protected mute/unmute. No matching router, render, recovery, or protection failures found.

## Limits and retained evidence

User confirmed playback “sounds good” after this installed-build test. Passive counters cannot establish absence of audible distortion or gaps. Calculator does not exercise an audio-producing application's tap-membership change. No acoustic capture or sustained soak of the latest app build was performed.

Evidence: `.build-dev/install-tested-bam.log`, `.build-dev/installed-audio-test.jsonl`, `.build-dev/installed-app-transitions.jsonl`.
