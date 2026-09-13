# Startup readiness repair

User reported “Audio engine couldn't start” on v1.0.7. Output independence was preserved throughout diagnosis and repair; no system-default change was made.

## Evidence and cause

Process23025 repeatedly created and stopped aggregates. A two-second stack sample showed the engine in its500ms readiness wait, AudioDeviceStop, and aggregate creation within the same retry flow. Its diagnostics requests timed out while the engine actor was occupied.

Instrumented process42275 reported valid tap formats but **zero callback starts** before the readiness cutoff. The callback was not rejecting malformed buffers; it had not been invoked. Aggregate teardown generated HAL device-list events, which immediately retried the failed build and bypassed the intended backoff.

After retaining the started aggregate, process75385 logged a pending start at17:04:46.627 and promoted that same aggregate to ready at17:04:52.365. Subsequent diagnostics showed generation1/build1 and advancing valid callbacks. This establishes that destroying the aggregate at the first500ms timeout prevented a delayed startup from completing on this setup.

## Repair

- A successfully started aggregate remains pending and hardware-protected across readiness timeouts. Matching retries reuse its tap/aggregate identities instead of resetting startup.
- Fresh valid callback and format checks are still required before promotion, health monitoring or playback restoration. Pending routing does not report isRunning.
- Invalid formats or failed IO retain the checked teardown behavior. Closing invalidates pending/live signatures even when resource destruction fails.
- Failed-build HAL events no longer bypass the existing2–30second heartbeat; explicit user reconfiguration remains immediate.
- Startup rejection logs include atomic callback/layout observations, collected without callback allocation or locking and never used as authorization.
- Explicit master-unmute clears a whole-device mute captured after failed startup, while preserving partial channel mute calibration and exact stock state for exit.
- Engine-side gates prevent all public unmute paths from releasing pending, uncertain or partially closed routing. Valid mute intent is retained for later recovery; a regression verifies deferred release only after readiness.

## Verification and installation

Final full tests passed: 157 package XCTest cases (2 opt-in hardware tests skipped), 54 Swift Testing cases, 56 App tests, 5 Python collector tests and WAV analyzer self-test. Release build and static analysis passed. Independent review found and closed a public-unmute bypass of engine-owned pending recovery; no remaining P1/P2 was reported in the reviewed repair.

Installed final repaired build PID79887; source/installed executable SHA256:

`6d124fc5d7eeb13c13590593ed0db25d5f0513387e334c87270449132ce49c48`

The user changed BAM's selection during diagnosis, first to Mac mini Speakers and then back to Razer; the current choice was preserved. macOS remained on Odyssey throughout. Final physical Razer state was unmuted at approximately 12%. Backup: `.build-dev/independent-backup.k2gzP1`; original released bundle/config/preferences are also retained in `.build-dev/startup-diagnostic-backup.oxHWdt`.

An earlier post-install sample overlapped a user-triggered output change and timed out; logs showed the changed route subsequently promoting to ready without a rebuild loop. Final stable runtime evidence is `.build-dev/startup-passive-health.jsonl`, installation evidence `.build-dev/startup-complete-install.log`, and original stack evidence `.build-dev/startup-failure-2026-09-11.sample.txt`. This is an installed local repair, not a published release. Subjective playback feedback is pending; no acoustic peak-containment claim is made.

Final observation clarification: the original fixed-deadline collector captured four healthy snapshots before a diagnostic timeout. A follow-up sample showed ordinary HAL reads in the health monitor, with no new readiness or recovery failure logs. One 117.9 ms callback outlier/one budget overrun was observed around profiling; causation is not established. A subsequent bounded passive run completed with ten running-engine snapshots and advancing callbacks on generation1/build1, zero build/render failures and no additional budget overruns or host-time misses. Diagnostic response delays remain an observation limitation; the startup/build loop itself is resolved.
