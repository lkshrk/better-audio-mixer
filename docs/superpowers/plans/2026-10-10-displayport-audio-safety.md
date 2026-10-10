# DisplayPort Audio Safety Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Mac panicking while audio plays through a DisplayPort/HDMI monitor. Make bam never hold display-audio IO across a display power transition, and warn when the system itself does.

**Status (2026-10-10):** Tasks 1-4 implemented; Task 5 (hardware verification) pending.

**Status of prior work:** `ee3e333` already stops bam's router on `screensDidSleep` when *bam's* output is display audio, and stops the 30 s silent-start retry loop. This plan closes the remaining gaps.

## Evidence

- Panic 2026-10-05 16:34: `DCPEXT0 PANIC - power_down_M3: auto_mode_change failed with 0x8000000f` (AppleDCP-1317.1.1, macOS 27.0.1 26A434, M4). It was followed at 19:06 and 20:02 by WindowServer watchdog panics (`initialization not complete (post IOKitWaitQuiet)`).
- A normal display sleep (2026-10-09 17:11:21) runs the same firmware path: `IOMFB: power on -> off` → `power_down_M3: request mode change: Auto` → `disabling M3` → `shutdown_link_gated`. `DCPAVAudioInterfaceProxy` is torn down on that same link. DP audio is carried on the link DCP powers down.
- The owner confirmed that moving both the macOS default and bam's output off the DP monitor stopped the panics. No panic has occurred since 2026-10-05.
- The Odyssey G60SD's audio endpoint exposes no volume or mute controls (`kAudioDevicePropertyVolumeScalar`/`Mute` absent), so control writes never reached it. IO is the only interaction.
- Hypothesis (not proven): with an IO stream running on the display-audio endpoint, DCP must tear down a live audio stream inside `auto_mode_change`. On this firmware that race sometimes fails. Every display power-off, idle sleep, lock or mode change runs it.

## Remaining gaps after `ee3e333`

1. **The macOS default output is untouched, and bam does not take it over.** Taps attach to the macOS default (`CoreAudioEngine.tapCaptureOutputUID()` returns `ProcessEnumerator.defaultOutputDeviceUID()`), and `.mutedWhenTapped` only zeroes the apps' samples. The default device keeps running: on 2026-10-10 the default `Mac mini Speakers` showed `kAudioDevicePropertyDeviceIsRunningSomewhere=1` while bam rendered to the Razer. With the default on the DP monitor, the DP link carries live (silent) IO whatever bam does, including after bam's router stops.
2. **No pre-emptive stop.** `screensDidSleepNotification` posts *after* WindowServer has started powering displays down. In the 17:11:21 log, the notification and `power_on -> off` land in the same millisecond, so bam's stop races the firmware.
3. **Other power transitions are not covered:** a resolution, refresh or rotation change; a hotplug; a lock screen without sleep; system sleep.
4. **The user is never told that display audio is risky.**

## Approach options

| Option | What | Covers | Cost / risk |
|---|---|---|---|
| A. Warn on select | Badge plus confirm dialog when picking an HDMI/DP output, in bam and in the macOS-default picker bam shows | gap 4 | Small. Doesn't prevent anything. |
| B. Stop earlier | Also act on `NSWorkspace.willSleepNotification`, `com.apple.screenIsLocked`, and `CGDisplayRegisterReconfigurationCallback` with `kCGDisplayBeginConfigurationFlag` for the display that owns the audio endpoint | gaps 2, 3 | Medium. The begin-config callback fires before the mode change, so this is the earliest hook available. |
| C. Move the system default off display audio during transitions | On begin-transition, if the macOS default is display audio, switch it to a safe device (built-in or last non-display), then restore it after the transition settles | gap 1 | Touches the macOS default. That conflicts with the documented owner rule "never align or set the system default automatically" (pitfall `output-device-binding`). **Needs owner approval.** |
| D. Route display audio only through bam | Detect "macOS default = display audio" and offer to point the default at bam's path instead (keep the default on a non-display device and let bam render to the monitor), so bam alone owns the IO and can stop it | gap 1 without a per-transition switch | One-time user consent. Relies on bam's own stop working. |
| E. Block display audio entirely | Hide HDMI/DP devices from bam's output picker | everything bam controls | Removes a feature. |

**Decision (owner, 2026-10-10): bam never changes the macOS default, so C and D are out.** Do A + B, with a persistent warning for gap 1.

## Tasks

### Task 1: Classify display audio once

- [x] Add `AudioDevice.isDisplayAudio` in `BamKit/Sources/BamCore/ConfigStore.swift`. It is true for transport `hdmi`/`dprt` or `OutputDeviceKind.displaySpeakers`/`.television`. Replace `ConsoleViewModel.isDisplayAudio(_:)` with it.
- [x] Swift Testing cases in `OutputDeviceKindTests`: DP transport with a speaker-like name; HDMI TV; USB headset (false); built-in (false).

### Task 2: Begin/end display-transition signal (option B)

- [x] New `App/DisplayTransitionMonitor.swift` publishes `.begin` and `.end`:
  - `.begin` comes from `CGDisplayRegisterReconfigurationCallback` with `kCGDisplayBeginConfigurationFlag`, from `NSWorkspace.screensDidSleepNotification`, `NSWorkspace.willSleepNotification`, and the `com.apple.screenIsLocked` distributed notification.
  - `.end` comes from the reconfiguration callback without the begin flag, `screensDidWakeNotification`, `didWakeNotification` and `com.apple.screenIsUnlocked`, debounced (about 1.5 s quiet) so a burst of reconfigure callbacks produces one `.end`.
  - Keep a reference count of open begins so that overlapping begins (sleep plus reconfigure) end only when all are done.
- [x] Replace the `screensDidSleep`/`screensDidWake` wiring in `BamApp` with this monitor. `ConsoleViewModel.screensDidSleep/Wake` become `displayTransitionBegan/Ended`; keep the serialized `enqueueScreenTransition` and the `displaySleepSuspended` gate from `ee3e333`.
- [x] The begin handler must be fast. Do the bound-device check from cached `outputDevices` and `boundOutputUID` state, never a HAL read, before calling `stopRouterGuarded`.
- [x] Tests: the monitor's debounce/refcount logic as a pure type (Swift Testing). Also add view-model tests: begin then end resumes; overlapping begins keep routing down until the last end; reconfigure-only begin/end on a non-display output is a no-op.

### Task 3: Warn on display-audio selection (option A)

- [x] In the output picker (`ChannelStrip` / menu bar output menu), show a warning symbol next to display-audio devices.
- [x] ~~One-time confirmation on selection~~ dropped: display audio stays selectable and bam pauses it itself, so the badge tooltip is enough.
- [x] If the macOS default is display audio at launch or after a default-output change, show a non-blocking banner (`configWarning`-style): "macOS is sending audio to <monitor>. Display audio has caused system freezes on this Mac; prefer another output."
- [x] Tests: view-model tests for the acknowledgement flag and the banner condition.

### Task 4: Make the system-default risk explicit (owner decision 2026-10-10: bam never changes the macOS default)

Options C and D are rejected. bam cannot free the DP link while the macOS default is the monitor, so the only remedy is telling the user.

- [x] Make the Task 3 banner persistent (not dismiss-once) while the macOS default is display audio. It should name the device and say what to do: "Set the macOS output to another device; bam can still play to <monitor>."
- [x] In the diagnostics report (`ConsoleDiagnostics`), add `systemOutputIsDisplayAudio: true/false`, so a future freeze report shows the risky state at a glance.

### Task 5: Verification on hardware

- [x] `make test` green (92 app + BamKit, 2026-10-10).
- [ ] Manual test matrix on the M4 + Odyssey G60SD (DP, 120 Hz, rotated). For each case, with music playing, run 20 display sleep/wake cycles (`pmset displaysleepnow`, then a key press), 5 lock/unlock cycles, and 5 rotation or refresh changes:
  1. bam output = Odyssey, macOS default = PA279CDV/other.
  2. bam output = Odyssey, macOS default = Odyssey (expect the banner; this is the residual-risk case).
- [ ] After each run, check `/Library/Logs/DiagnosticReports/*.panic` for `DCPEXT`, and check the `log show --predicate 'subsystem == "me.harke.bam"'` output for `suspending routing` / `resuming routing` pairs.
- [ ] Record results in the vault pitfall `projects/better-audio-mixer/pitfalls/displayport-audio-output-panics.md`.


## Probe results (2026-10-10, `/tmp/dpprobe`, generic over every HDMI/DP output device)

- `kAudioStreamPropertyIsActive = 0` on the output stream is accepted (`noErr`) but has no effect: another process kept rendering at 95 IO cycles/s.
- `kAudioDevicePropertyHogMode` taken by bam (bam itself doing no IO): another process's IO dropped to 0, and coreaudiod logged `StopIO` and `IOWorkLoopDeinit` for the device and released its power assertion. On release, the same process resumed (`StartIO`) without restarting. The macOS default output was unchanged.
- The hog owner was killed with `kill -9`: coreaudiod released hog by itself (`hog=-1`) and playback worked. A crashed bam cannot leave a device stuck.
- Apple Silicon has no `IODisplayWrangler`, so no pre-display-sleep hook exists. `screensDidSleep` arrives in the same millisecond as the DCP power-off.

## Task 6: Quiesce every display-audio device across transitions (generic)

- [ ] `DisplayAudioQuiescer` in AudioEngine: on begin, take hog mode on every HDMI/DP output device that has output streams (no name checks). On end, release only what it took. Never touch the macOS default.
- [ ] Skip devices already hogged by another process, and log them.
- [ ] Tests via injected device ops: takes only display devices, releases only its own, release is idempotent, and a failed take is reported.

## Task 7: Own display idle sleep while display audio is active (generic)

- [ ] While any display-audio device is running (`DeviceIsRunningSomewhere`), hold `PreventUserIdleDisplaySleep` (IOPMAssertion).
- [ ] Track idle time with `CGEventSource.secondsSinceLastEventType`, compared against the `displaysleep` minutes from `IOPMCopyPMSetting`/`pmset`. When idle reaches it: quiesce (Task 6) first, then release the assertion so macOS sleeps the display with no audio IO on the link.
- [ ] On user activity or wake, the transition ends through the gate and hog is released.
- [ ] If `displaysleep` is 0 (never), do nothing.

## Out of scope

- Fixing Apple's DCP firmware. File Feedback Assistant with the three `.panic` files and the reproduction steps.
- The Moonlight exclusive-fullscreen and Corsair driver suspects. The owner confirmed DP audio as the cause.

## Open questions for the owner

1. ~~May bam change the macOS default?~~ No (2026-10-10).
2. ~~Hide display audio (option E)?~~ No: it stays selectable, with a warning badge (2026-10-10).

## Outcome of Tasks 6/7 (2026-10-10)

Reverted. Hardware test 01:38: hog arrived after `Display set power state 0` on manual sleep, and coreaudiod had already restarted the display IO before it. A freeze at 02:00 (reboot 02:03, no panic file) occurred while bam was idle; that window also had a bluetoothd SIGABRT loop (8 crashes 01:57-02:02) and the Odyssey's audio device deactivating at 02:00:05 with no display power-off. The cause is unattributed. Next diagnostic step: run without bam, with the macOS output on the Odyssey, to separate macOS/firmware from bam.
