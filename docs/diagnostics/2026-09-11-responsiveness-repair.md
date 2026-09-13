# Responsiveness regression

User reported lagging controls/meters and slow startup after the startup-readiness repair.

## Evidence

A one-second sample of installed PID94943 spent 870 samples in `playingBundleIDs` → `ProcessEnumerator.allProcesses` → HAL property reads on the engine actor. Controls and meter reads shared that actor. Eight baseline diagnostics requests included 494 ms and a 3-second timeout.

The first responsiveness build (`bb21deb25f51c434c79a84e2956bc343a24e920f764269d2138bb978c777ceec`) produced 16 steady-state diagnostic replies in 0.11–0.42 ms, and 169 meter frames in six seconds (68 distinct payloads, maximum observed gap162 ms). These measure transport/engine responsiveness, not acoustic latency or visual smoothness. Startup still stalled: launched18:29:07, pending readiness18:29:18, early diagnostics timed out before recovery completed.

## Changes

- Polling and health HAL reads run outside the engine actor; health observations are rejected after route/generation changes. Metadata polling omits unused device lists; playing indicators only fetch bundle IDs for active processes.
- Startup stages the saved master value and applies it once while protected. Removed the post-start24-write ramp and indefinite audible-input wait. Explicit output-switch fading remains.
- Delayed volume reads/writes cannot overwrite newer fader intent. Saved/newer intent follows a rebound physical UID before unmute; stock calibration remains independent.
- Exact output selection now uses direct UID translation and output-stream validation. Full device enumeration remains for missing/rebound selections. Startup skips an empty prior-output protection intersection. This removes four avoidable whole-device scans in the ordinary startup path.

## Verification

Regression coverage includes blocked playing/health scans, obsolete health results, delayed fader completion, saved startup level, rebound UID updates, pending-router reuse and protected unmute. Independent read-only review reported no new P1/P2 findings.

An incremental package test runner hit SIGBUS in an async continuation after MockAudioEngine layout changes. A separate fresh package build passed; clearing only the package build cache restored normal full-suite execution. No source workaround was introduced for the stale build.

Final installation/measurement results follow below. Output selections remain independent and user-owned. No public release is part of this repair.

The next installed build (`5efdbd4e…`) confirmed readiness at21.7 seconds, with one aggregate build and no callback budget overruns. Steady control replies were0.12–0.23 ms;156 meter frames arrived in six seconds, with maximum gap206 ms. Startup is still a known latency limitation; these measurements do not justify calling it fast.

Physical verification then found mute1 despite UI unmute. Explicit-unmute handling previously skipped retained guards or discarded restore failures. It now logs retained protection and surfaces failed restoration through the existing error/status path; a mock regression covers this. Engine diagnostics distinguish pending readiness from accepted-but-unconfirmed hardware-write protection. Uncertainty is never cleared merely because the renderer is running.

The local installer also now restores pre-install configuration before launching: its temporary safety mute must not become persistent startup intent. Final tests after the release-reporting change:160 package XCTest (2 opt-in hardware skips),54 Swift Testing,61 App tests,5 Python collector tests and analyzer self-test; Release build/static analysis and diff checks pass.

## Final installed state

Installed signed executable SHA256 `a0ee29e97ab6fdaca308cf24ae8433d16c65ec7df04f804e7ddc17e6950d7269`, matching the built product. Rollback bundle/config/preferences: `.build-dev/independent-backup.kZcWe2`. Engine logs confirm both startup and subsequent explicit unmute applied successfully; the independent physical probe confirms mute0 and volume0.121502, with the same macOS default UID before/after.

First observed renderer readiness was21.85 seconds. Startup remains slow and is not claimed resolved. Steady control responsiveness has improved substantially; acoustic playback quality and perceived slider/meter smoothness require user observation. No release was published. Evidence: `.build-dev/responsiveness-release-check-install.log`, `.build-dev/control-latency-installed-final.jsonl`, `.build-dev/responsiveness-final-tests.log`, `.build-dev/responsiveness-release.log`.

Final eight diagnostic replies ranged0.19–168.87 ms, with five below0.5 ms and no timeouts. The168.87 ms tail means residual response jitter remains; the earlier submillisecond sample is not a blanket latency guarantee.
