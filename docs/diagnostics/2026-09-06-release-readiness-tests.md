# Release readiness tests — 2026-09-06

Local automated checks passed. Public-release readiness still requires final-build hardware validation and hosted CI.

## Fresh verification

- `make test`: 119 package XCTest cases, including 2 opt-in hardware skips; 53 Swift Testing cases; 49 App XCTest cases; zero failures.
- WAV analyzer self-test and all 5 collector tests passed.
- Release `xcodebuild build analyze`, forced lockfile resolution, signing disabled: both succeeded. Only reported build warning: AppIntents metadata extraction skipped because there is no AppIntents framework dependency.
- `actionlint -shellcheck= -pyflakes=` and `git diff --check` passed.
- Logs: `.build-dev/release-readiness-test.log` and `.build-dev/release-readiness-build.log`.

## Installed runtime observation

Independent read-only subagent observed both processes for 79 seconds:

| Process | Elapsed runtime | Physical footprint | Lifetime peak | RSS start → end |
| --- | --- | --- | --- | --- |
| bam, PID 7483 | 8h40m | 40 MB | 41 MB | 37,696 → 37,120 KiB |
| BAMStreamDeck, PID 86044 | 9h43m | 11 MB | 11 MB | 17,680 → 16,624 KiB |

No footprint growth observed. Last 15 minutes of logs contained no matching router, render, underrun, overrun, overload, or recovery failures. Two XPC interruptions reported successful reinitialization.

## Limits

The installed app predates the latest source. These passive observations do not test audible distortion, acoustic latency, or application-open/close transitions. The two live routing tests were skipped. No output controls, routing, or running applications were changed during this validation. The new Release product is unsigned and was not installed. Pending changes remain uncommitted; hosted CI has not run for them.
