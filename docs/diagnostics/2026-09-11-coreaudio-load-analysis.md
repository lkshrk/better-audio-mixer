# CoreAudio load and remaining lag — analysis only

No source changes, builds, installations, restarts, or audio-setting changes were performed for this analysis. Two independent reviewers examined startup and responsiveness. Existing installed PID62929 remained running.

## Findings

### 1. The polling fix reduced actor blocking but retained excessive HAL work

Before stack sampling, `ps` reported coreaudiod106.1% CPU and bam11.8%. This is a point observation, not a sustained CPU benchmark or proof that BAM causes all daemon CPU usage.

A fresh5ms stack sample shows all156 samples of BAM's utility worker in `checkRouterHealth` → `ProcessEnumerator.allProcesses` → CoreAudio property reads. The sampled main thread mostly waits in its event loop. This confirms the expensive scan remains in the installed build, now outside the engine actor. It does not measure how much CPU the daemon spends serving it.

App polling (`App/ConsoleViewModel.swift:245`) and health monitoring (`BamKit/Sources/AudioEngine/CoreAudioEngine.swift:1056`) independently repeat after work plus two seconds. Event reconciliation (`App/ConsoleViewModel.swift:353`) can add device/process/topology scans. No shared scan result or single-flight coordination exists across these paths; detached execution permits overlap.

Normal successful property-call counts, with P processes, R running processes, D devices, O output devices and T taps:

| Operation | Approximate HAL calls per scan |
|---|---:|
| Playing apps | 2 + P + R |
| Router health | 4 + 3P + T |
| Output devices | 2 + D + 4O |

Counts derive from `ProcessEnumerator.swift:20–53,115–131` and `CoreAudioEngine.swift:1086`; array size/data reads and device-name fallbacks affect actual totals. These are static counts, not a captured call-rate trace. Health reads PID and inactive-process metadata even though its expected-audible-source decision uses running state and bundle identity.

### 2. Hardware master controls still block the shared control path

Each executed master target captures complete device state in `ConsoleViewModel+Volume.swift:455`, then `restoreDeviceState` captures it again (`CoreAudioEngine.swift:388`) before checked channel writes. Confirmation performs UID/current-device and readback checks and may synchronously wait up to0.5s per attempt (`CoreAudioProperty.swift:49,84`).

Those operations still occupy the engine actor serving meters/diagnostics. Gains also share a FIFO with hardware writes and reconciliation (`ConsoleViewModel.swift:528`). Thus a responsive idle diagnostic endpoint does not establish responsive faders during hardware writes. The24-step fade was removed from launch but remains on explicit output switches.

### 3. Event handling can add load without an actual topology change

The event stream buffers one pending event, but sustained events still cause repeated output enumeration and synchronous `canKeepCurrentRouter` preflight. Preflight includes a full process scan plus device/rate/tap-format checks (`CoreAudioEngine.swift:740–774`). A current event storm has not been demonstrated; this is an identified amplification path, not a proven active loop.

### 4. Startup timing was overstated as an internal measurement

The final build's measured `agg.start` duration was4.625s: one attempt, one success, generation1. Six tap creations and their format reads occur before this timer. Initial stock capture and later protection/restore validation also add work.

The21.849s installer value is the first successful external readiness observation. It includes fresh Python collector launches, separate handshake/diagnostics deadlines, failed attempts and one-second polling sleeps. It is an upper bound, not an internal ready timestamp. Saved logs for the final PID show a pending zero-callback rejection at18:46:01.958 and aggregate promotion at18:46:11.432; process launch was18:45:49.587. This corroborates a long setup/promotion interval but does not time first valid callbacks.

Pending startup retries re-enter protection/topology work before readiness checks. Heartbeat2→4→8s delays can postpone recognition after callbacks start. Removing redundant whole-device scans did not establish a meaningful measured startup improvement.

## Verification and limits

- Forty read-only diagnostic requests before profiling: median0.259ms, p95 4.80ms, max19.54ms, no timeouts. These are socket/diagnostics response times, not gain application or acoustic latency.
- CoreAudio logged IO overload warnings around18:51:39–41, overlapping our brief BAM sampling. Profiling is a confounder; these messages are not evidence of an uninstrumented overload rate.
- Direct coreaudiod stack access required administrator authorization unavailable to this session. No password was requested and the daemon was not restarted. Its CPU cannot yet be apportioned between property traffic, rendering, drivers, or other clients.
- Evidence: `.build-dev/analysis-bam.sample.txt`, `analysis-control-latency.jsonl`, `analysis-coreaudiod.log`, and prior `responsiveness-release-check-install.log`.

## Recommended next change, not implemented

First reduce HAL demand: share one bounded process/activity snapshot between UI and health, refresh the device list on relevant changes, and coalesce event reconciliation. Avoid fetching inactive-process metadata for audible-source checks. Preserve freshness requirements for health decisions and all identity/calibration/protected-release validation.

Then separate slow hardware-control work from gains/meters while retaining serialized writes and topology ownership. Coalesce master targets before expensive capture/write work. Do not remove safety checks or clear uncertain writes to make controls appear faster.

For startup, time individual tap creation, aggregate creation/start, first valid callback and hardware release separately. A future verification should measure idle CoreAudio CPU/property-call rate and actual fader-to-applied-gain latency, without profiling during the timing run. Another installation is not part of the current request.
