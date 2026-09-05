# BAM memory growth and app-lifecycle audio glitches

Historical pre-fix investigation; see [implementation results](2026-09-05-implementation.md) for subsequent changes and verification.

Investigation: 2026-09-05. Three independent agents examined Stream Deck memory, Swift audio lifecycle, and the C driver. Parent collected live memory evidence and ran targeted tests. Application source and running audio configuration were not changed.

## Conclusions

1. **Confirmed source defect, reproduced:** BAMStreamDeck's socket parser retains consumed input in a growing `Data` allocation. This strongly matches the live 7.6 GiB footprint.
2. **Confirmed source behavior, strong symptom match:** process/device notifications enter the hardware mute guard even when routing is unchanged. Those unnecessary mute cycles can explain unrelated-app launch/exit glitches.
3. **Separate, intentional interruption:** actual grouped-process changes rebuild the shared aggregate. Removing no-op mute cycles will not eliminate those rebuild gaps.
4. **Preserve ear safety:** hardware muting prevents historical full-volume bursts. It must remain around actual or uncertain routing changes, startup, permission handling, and recovery.

## Memory evidence

Live installed BAMStreamDeck PID 51330 had approximately six days and two hours uptime. `vmmap -summary 51330` reported a 7.6G physical footprint. `footprint -p 51330` reported 7775 MB total, including 7757 MB MALLOC_REALLOC. Almost all of that storage was swapped out; `ps` showed only about 16 MB RSS. RSS alone therefore concealed the problem.

At `BamKit/Sources/BAMStreamDeck/UDSClient.swift:81-86`, incoming bytes are appended, each complete line is copied, and the remaining slice is assigned back:

```swift
readBuffer = readBuffer[readBuffer.index(after: idx)...]
```

The reproduced behavior on this Mac is that the slice advances its start index while retaining the consumed prefix in backing storage. Subsequent appends grow that allocation. An empty logical buffer does not imply released storage.

The standalone [reproducer](bam-data-retention.swift) isolates this operation without sockets, rendering, or WebSockets. One million complete 200-byte frames produced:

| Operation | Remaining bytes | startIndex | Peak RSS, bytes |
| --- | ---: | ---: | ---: |
| Existing slice assignment | 0 | 200,000,000 | 208,093,184 |
| Copy tail with `Data(tail)` | 0 | 0 | 6,045,696 |
| Remove consumed subrange | 0 | 0 | 6,045,696 |

Existing behavior grew approximately 40 MB per 200,000 frames. Both alternatives passed fragmented input, multiple lines per chunk, empty-line skipping, and trailing partial-frame checks. Roughly 15 KB/s received over the observed uptime is sufficient to account for the reported growth. `ControlServer.swift:446-480` sends meter frames approximately 30 times per second even without control changes.

**Minimal recommended fix:** replace the slice assignment with `readBuffer.removeSubrange(readBuffer.startIndex...idx)`. The server already uses this exact pattern at `BamKit/Sources/BamControlKit/ControlServer.swift:310`.

The live allocation was not traced to an owning stack, and the installed binary was not matched to the checkout revision. The source defect and isolated reproduction are confirmed; attribution of all live memory to that exact source revision remains an inference.

## Audio interruption chain

1. `CoreAudioEngine.swift:742-771` yields process-list, device-list, and default-output notifications.
2. `App/ConsoleViewModel.swift:320-332` refreshes devices and reconciles for every event.
3. Reconciliation at `ConsoleViewModel.swift:246-247` invokes `startRouterGuarded`.
4. `App/ConsoleViewModel+Volume.swift:91-104` saves output volume, mutes hardware, invokes the engine, mutes again, restores volume, and unmutes.
5. The unchanged aggregate-signature path at `CoreAudioEngine.swift:426-432` runs **inside** that mute window.

Thus an event with no routing change can still briefly silence playback. This is a source-level causal path; waveform capture during app launch was not performed.

### Safety-preserving correction

Skip the guard only after a **side-effect-free, serialized check** proves that the active router is healthy and its resolved routing is unchanged. Preserve the guard for changed PID membership, remainder exclusions, capture/output devices, startup, permissions, recovery, failures, and uncertain state.

Do not invoke the existing `startRouter` as a dry-run: it can create taps at line 399 and replace tap ownership at line 414 before reaching its signature check. Mute must precede any such mutation. Serialize preflight with the action so a concurrent output switch or queued topology edit cannot invalidate the check. Preserve master-muted state and existing output-switch fade ownership.

Do not remove the mute wrapper, move it after tap creation, or blindly switch to overlapping aggregate creation. Prior bug-174 records full-volume bursts and fixed-UID constraints. The user's explicit requirement is to retain protection against moments of maximum-volume audio.

### Genuine topology changes

`CoreAudioEngine.swift:354-365` includes live process-object IDs in source signatures; grouped helper launches/exits can change a tap and the remainder exclusion set. Lines 443-451 tear down the shared aggregate before creating its replacement. `RouterAggregate.swift:544-552` stops I/O and destroys it. Its 2048-frame fade restarts (`96`, `397-418`), approximately 42.7 ms at 48 kHz, in addition to setup time.

These real changes interrupt all sources sharing the aggregate. First measure them with existing `CoreAudioEngine.rebuildAggregate` and `RouterAggregate.create` signposts. Seamless membership changes require separate platform validation; they are not a safe one-line follow-on to the no-op fix.

The default-unbounded event stream (`CoreAudioEngine.swift:744`) also processes every notification separately. Latest-state invalidations can potentially be coalesced with `bufferingNewest(1)` and serialized reconciliation; event-storm frequency has not been measured. This stream belongs to BAM, not the separate BAMStreamDeck process.

## Lower-priority findings and exclusions

- `ActionRouter.swift:93-94,482-504,524-538`: full-state replacement does not prune `levels` and `peakWindows` for missing IDs. Follow-up planning inspection confirmed explicit `removed` events already clear both at 431-435, so ordinary received deletion events are handled. Reconnect/full-state replacement without those events can retain stale entries. Prune against authoritative state IDs; this is much less convincing as the normal 8 GB cause.
- `ElgatoConnection.swift:47-53`: no application-level bound on pending WebSocket sends. Slow-consumer accumulation is possible, not demonstrated; defer transport redesign until after the confirmed buffer fix.
- `BAMDriver.c:882-919`: add/remove client callbacks validate arguments and otherwise do nothing. The I/O callback at 4237-4316 has no mutex/allocation; lifecycle StateMutex does not block it.
- Driver PCM rings are bounded to eight slots × 65,536 frames × stereo Float32 = 4 MiB, allocated in the driver host rather than BAMStreamDeck. Current aggregate code uses the output hardware subdevice, not the historical ring bridge.
- Conditional driver hardening: identical MixConfig writes still notify DeviceList (`1627-1633`), and first StartIO does not handle allocation failure (`4064`). Neither is established as a cause of these reported symptoms.
- Some `.wolf/anatomy.md` entries describe removed ring-bridge files. Current source was used to resolve that documentation drift.

## Verification and next checks

Ran `swift test --filter 'BAMStreamDeckTests|BamControlKitTests|AudioEngineTests'` from `BamKit`: 60 XCTest tests executed, two hardware smoke tests skipped, zero failures; 34 Swift Testing tests passed. This was baseline verification, not verification of an applied fix. AppTests were not run.

Existing rendering/control tests do not exercise long-run UDS retention. The gain-only guard test calls `updateRouterGains` directly and misses the view-model event wrapper. Guarded manual restart coverage must remain intact.

Recommended regression sequence:

1. Exercise the actual UDS parser with many complete and fragmented frames; verify consumed storage stays bounded and incomplete bytes survive. Run a plugin soak afterward.
2. Emit unrelated process/device notifications into a healthy view model; assert zero hardware mute/volume writes and zero tap/aggregate mutations when resolved topology is unchanged.
3. For real PID/output changes, startup, permissions, unhealthy recovery, errors, and concurrent edits, assert mute happens before the first tap/aggregate mutation. Verify master-muted state and failure behavior do not expose unattenuated playback.
4. Capture output waveform and peak levels during unrelated and grouped app launch/exit, with mixed gains and muted sources. Correlate gaps with guard writes and rebuild signposts. Counting rebuilds alone does not validate ear safety.

Reproduce the bounded memory experiment on macOS:

```sh
swiftc -O docs/diagnostics/bam-data-retention.swift -o /tmp/bam-data-retention
/tmp/bam-data-retention
/tmp/bam-data-retention fixed
/tmp/bam-data-retention remove
```

Graph coverage was checked for cited code paths. Partial parser ranges in CoreAudioEngine and BAMDriver were inspected directly. No fixes, installations, process restarts, or hardware route changes were made.
