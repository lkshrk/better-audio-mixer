# Volume-origin follow-up

**User clarification:** the user confirmed “it was me” after the master-Fader trace. The reproduced100% request was their fader adjustment, not an unexplained automatic jump. Low-level listening monitoring resumes; the separate Stream Deck wrap fix remains valid.

Continued diagnosis with hardware muted. Two independent agents traced controls and restoration; parent added origin logging and deployed the verified app/helper under protection.

## Concrete control fix

Stream Deck master adjustment previously used a cached percentage to wrap a negative step at zero to an absolute 100%. It now always sends `nudgeMasterPos`, letting BAM clamp against its current level. Eight parameterized regressions cover missing state, cached 0/12/100%, and both directions. Unrelated mix controls remain unchanged. This was a reproducible hazard, but is not attributed as the cause of the original incident.

## New evidence

Instrumented app PID71644 logged another high-volume request:

- **14:28:19.995 local:** `hardware volume requested origin=ui target=1.000000`.
- **14:28:19.999:** queued apply and state restore both targeted 1.000000.
- No corresponding control command receipt/execution or recovery event.

The sole current caller using the default `ui` origin is the master Fader commit callback in `App/ChannelStrip.swift:35`. The Fader commits on gesture completion; source inspection found no initialization/resize callback that commits by itself. The user subsequently confirmed the adjustment was theirs, resolving the suspected automatic-volume issue.

Known diagnostic commands behaved correctly: zero then down-at-zero stayed zero; subsequent low command requested/applied0.12. Receipt-to-execution delays observed were approximately0.038–8.70ms, not a multi-second command backlog. Parent restored low volume and mute after the high request, then resumed monitored playback after the user's clarification.

## Verification and deployment

Full tests passed:144 package XCTest cases (2 opt-in hardware skips),54 Swift Testing cases,50 App tests, Python collector tests and WAV self-test. App Release build/static analysis and universal helper build passed.

- App source/installed SHA256: `e617b52af5e5fbb4630d628cd70cd06278fd7c8f51490b9bdeecd7056cf43995`.
- Helper source/installed SHA256: `52f1015438d8a9b5a179823be498790730c55a8f17fa6a921e50493803a8aae8`.
- App PID71644; helper PID75363. Both signed with the existing Developer ID.
- Rollback: `.build-dev/install-tested-backup.dveSN9` (app/preferences), `.build-dev/volume-helper-backup.gNNLCb` (helper).
- Final physical readback after monitored playback: scalar0.121502034, mute0. Playback remains enabled at approximately12%; subjective listening feedback is pending.

Evidence: `.build-dev/volume-origin-{tests,release,helper-build,install,helper-install}.log` and unified logs for PID71644. Existing first-sample/acoustic validation limits still apply.

## Completed low-level playback check

After the user's clarification, ran a90-second playback watchdog (88 snapshots spanning88.99seconds) and three isolated Brave audio launch/play/exit cycles (49 snapshots over39.15seconds) with playback enabled. Both completed without triggering protection. Master readback stayed exactly0.121502034 throughout the watchdog. The source-cycle monitor independently enforced low/unmuted master state while consuming updates.

Both runs stayed on router generation1 and one successful aggregate build, with zero build/render failures or buffer-budget overruns. Maximum lifetime callback duration seen during the source cycles was0.6383ms against10.67ms nominal buffer duration. Isolated browser instances exited and their temporary profiles were removed. Normal browser sessions were untouched.

Evidence: `.build-dev/volume-origin-listening.jsonl`, `.build-dev/persistent-membership-audible-cycles.jsonl`; both corresponding `.err` files are empty and both runners exited0. This establishes a bounded low-volume functional trial, not maximum-hardware-gain first-sample suppression or acoustic measurement. User sound-quality feedback remains outstanding.
