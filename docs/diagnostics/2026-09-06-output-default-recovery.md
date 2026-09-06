# Output restoration failure: default-device mismatch

Historical diagnosis of the older coupled implementation. The subsequent independent-output change removes the requirement to align macOS and BAM selections; see [the implementation](2026-09-06-decoupled-output-proposal.md).

User reported the generic restoration error persisting across app restarts. Initial process63399 exposed zero aggregate build attempts: failure occurred before router creation, not in the renderer or limiter.

A source-visible, read-only HAL probe established:

- macOS default output was Odyssey G60SD (device174), with no readable/writable volume or mute on the inspected output elements.
- BAM selected Razer BlackShark V2 Pro (device152), whose master controls were available; volume1.0, mute1.
- The engine includes both capture/default and render outputs in its protection set. It cannot protect the display output, so startup refuses the handoff. Restarting preserves the same system-default mismatch.

Recovery held BAM master mute, verified physical headset mute, lowered headset volume to approximately12%, and made the selected Razer device the macOS default. Every recovery property write required notification plus matching readback; no safety guard or uncertainty latch was disabled.

The app restarted during the check (current PID9551). It subsequently created six live taps and a running aggregate. Final physical readback: default Razer152, volume0.121502034, mute0. A subsequent15-snapshot health check is retained in `.build-dev/restoration-recovered.jsonl`; no current-process health/recovery failures were observed in the bounded log query.

The running bundle is still labelled1.0.5 with executable hashe617b52a…, the previously installed instrumented trial build. Publishing1.0.6 did not automatically replace this local bundle. No source-code or release change was required for this recovery. The arbitrary-ramp quantization hypothesis was investigated but does not explain the observed pre-start failure.

If macOS falls back to the monitor after disconnect/sleep, the same unsupported-default condition can recur. The selected BAM output and macOS default need to remain aligned for this headset routing setup. This recovery does not establish high-gain acoustic safety.
