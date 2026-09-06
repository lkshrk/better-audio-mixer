# Persistent membership: installed trial

**Later clarification:** the user confirmed the high-volume master-fader adjustment was theirs. The suspected automatic jump is resolved; see `2026-09-06-volume-origin-followup.md` for the corrected app/helper and subsequent listening check.

User confirmed headset off-ear. Installed the locally verified Release build, signed with the existing Developer ID. Source and installed executable SHA-256 match:

`5b33f8abf01a3a1d8daa23f7c9913980ac794e075917c563e5bd038c3e541f6b`

Installed PID: 60001. Rollback app/preferences: `.build-dev/install-tested-backup.mnftUh`. This is a local test build replacing the installed app for the trial, not a new published/Homebrew release.

## Startup and initial playback

Hardware mute and approximately 12% volume were verified before replacement. Startup created six persistent source taps and one aggregate at 48 kHz/512 frames. Telemetry reported running capture/render with zero build/render failures. Low-level playback was initially enabled; the user has not supplied listening feedback.

Before the planned audible browser trial, its low-level precondition found master at 100% instead of 12%. It aborted before launching any test browser. Parent immediately muted BAM and restored the low target.

Core Audio logs show BAM itself issued a scalar `1.0` write at **14:08:59.305 local time**, following unmute at 14:08:32.646. No nearby rebuild/recovery event explains it. An independent read-only reviewer found no unconditional automatic 100% setter; direct UI/control requests and restoration of previously captured state are possible paths. Logs do not identify the initiating call. User said “didnt try”; this does not establish the origin. Do not attribute the change to the user or declare a reproduced automatic-volume bug without further evidence.

## Muted audio-process lifecycle trial

Ran three isolated Brave Browser instances, each with its own temporary profile and a local page producing a six-second 220 Hz tone at 0.01 amplitude. Brave is already assigned to the configured Stream source. Normal browser profiles/sessions were not touched. Master mute and low volume remained required by the trial monitor throughout these cycles.

Across 49 snapshots over 39.31 seconds:

- Three launch/exit cycles completed; isolated browser instances exited.
- Router remained running on generation 1 with aggregate build attempts/successes fixed at 1.
- Zero aggregate build failures, limiter render failures, guarded samples, buffer-budget overruns or reported host-time misses.
- Maximum observed callback duration: 0.4087 ms against the 10.67 ms nominal buffer duration.

These counters show no shared aggregate rebuild during the trial; they do not independently record every tap ID/property write or measure acoustic suppression, first-sample behavior, gaps or latency. The three cycles ran muted, so they are not a successful listening test.

## Final state and evidence

Test build remains installed and **muted**. Physical Razer output readback after the cycles: scalar **0.121502034**, mute **1**. Normal listening is held pending attribution/control of the unexpected higher-volume request. No maximum-volume acoustic test was performed.

Evidence under `.build-dev/`: `persistent-membership-install.log`, `persistent-membership-startup.jsonl`, `persistent-membership-playback.jsonl`, `persistent-membership-cycles.jsonl`, `persistent-membership-cycles.err`, `run-membership-trial.py`, `membership-trial.html`. Passive observer saw no tap/format/protection failure logs and RSS decreased from 66,304 to 63,872 KB over its initial minute; this is not a sustained memory benchmark.
