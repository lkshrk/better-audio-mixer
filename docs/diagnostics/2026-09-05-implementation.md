# Memory and audio fix implementation

Implemented in the working tree using independent implementation, concurrency-test, and safety-review subagents. The installed BAM app, Stream Deck helper, audio driver, and hardware routing were not replaced or restarted.

## Changes

- **Stream Deck receive buffer:** consumes the parsed subrange instead of retaining a tail slice. Tests invoke the actual parser with repeated and fragmented frames, empty/malformed lines, and trailing partial input.
- **Meter state:** full snapshots prune missing mix IDs and stale meter frames cannot resurrect removed entries. Existing explicit removal and surviving peak history are preserved.
- **Unrelated application events:** an engine-owned, read-only check skips audio work only for the same healthy configuration, live process membership, device identities/formats, and current router generation. Unknown or changed state still takes the protected rebuild path.
- **Event ordering:** newest-only invalidations await the existing router queue, alongside user edits, manual restart, and heartbeat recovery. Stop/driver-disable invalidates and drains queued work.
- **Volume safety:** hardware writes report success/failure; intended per-device volume/mute survives failed attempts. Failed protection aborts mutation. Failed rebuild/restoration cannot authorize unmute. Output switches preserve the fade while honoring newer user intent.
- **Engine recovery:** protection precedes tap/aggregate teardown, including pause/rearm; failures schedule bounded retries. App protection suspends automatic recovery, and explicit restore acknowledgement works even while master-muted.
- **Device/health correctness:** reenumerated device objects force a protected rebuild; stale source counters and old-generation observations cannot permanently suppress healthy no-op checks.
- **Lifecycle:** startup no longer performs a redundant unconditional unmute. Checked stop restores ordinary playback only after successful teardown. Termination uses checked protection and detached teardown rather than a MainActor task blocked by its own semaphore wait.

No driver rewrite, new dependency, aggregate UID change, or overlapping unprotected tap creation was introduced.

## Verification

`make test` passed:

| Suite | Result |
| --- | --- |
| Package XCTest | 95 executed, 2 opt-in hardware skips, 0 failures |
| Package Swift Testing | 53 tests in 9 suites, passed |
| App XCTest | 35 tests, 0 failures |

The App result bundle also reports 35 passed, zero failed/skipped. Tests cover failures in protection/restoration, recovery ordering and retries, master mute, startup cancellation, queued teardown, latest intent during fades, failed switches, and event bursts.

`xcodebuild ... analyze` succeeded; `git diff --check` passed. The Xcode project was regenerated to include the new App concurrency tests.

The memory subagent captured 15 failing assertions before its fixes; its isolated Stream Deck run passed all 38 tests afterward. Engine safety regressions were added during implementation, so a before-fix engine test failure is not claimed. The first combined run caught a fader seed regression; it was corrected before the successful full run.

### Actual-parser memory soak

A temporary harness compiled the production `UDSClient.swift` and fed 300,000 frames / 1,208,100,000 bytes without connecting to an installed socket. One 201.35 MB warmup batch was followed by five equal batches:

| Measurement | Every measured batch |
| --- | ---: |
| Physical footprint | 2,490,824 bytes |
| Malloc bytes in use | 357,120 bytes |
| Compressed memory | 622,592 bytes |
| Remaining input | 1 byte, startIndex 0 |

All callbacks were checked. This demonstrates a plateau in the actual parser, including compressed-memory accounting, rather than relying on RSS alone. Temporary runnable evidence: `/tmp/bam-memory-soak/README.md`, `/tmp/bam-memory-soak/Soak.swift`, `/tmp/bam-memory-soak.log`.

## Remaining validation and limits

- Installed processes still run the previous binaries. These source fixes do not release the existing helper's retained memory until it is replaced/restarted.
- Physical output waveform and peak-level validation was not run. The two opt-in hardware tests were updated for checked protection but remain skipped. Hardware continuity/ear-safety is not proven by mocks.
- Genuine grouped-process/device changes still rebuild the shared aggregate under protection and can briefly interrupt audio. The no-op fix removes unnecessary mute/rebuild work; it does not promise seamless real topology changes.
- Devices without readable volume or complete supported hardware mute fail safely instead of allowing uncertain protection. Their compatibility needs device-specific validation.
- The controlled parser soak is not an hours-long end-to-end Elgato rendering/transport soak. A separate preexisting added-mix discovery issue in the control protocol remains outside this fix.

See the [reviewed plan](2026-09-05-fix-plan.md) for hardware acceptance criteria and rollback boundaries. Deployment has not been performed.
