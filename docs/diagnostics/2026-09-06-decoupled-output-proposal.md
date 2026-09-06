# Independent macOS and BAM outputs

Implemented the user's clarified contract: both outputs are user-selected and independent. There is no hardcoded device, designated silent-sink mode, or requirement that the macOS output be unused.

## Selection and ownership

- BAM retains its saved hardware output across app starts and macOS default changes. Only a missing initial selection is seeded from the system default.
- An absent selected BAM device stays unavailable instead of falling back to the macOS default. Exact UID or unambiguous stable USB identity still permits reconnect/re-enumeration.
- Failed routing and concurrent picker changes cannot overwrite the user's choice with the old bound output. The engine reports a new bound output only after the route succeeds.
- Capture follows the current macOS default. If no default exists, capture is unavailable rather than silently using the BAM listening output.
- Hardware protection includes current/previous BAM listening outputs and pending restoration owners. Capture-only devices remain part of topology/format validation but do not require volume/mute controls and receive no protection writes.
- Missing protection owners never authorize teardown of existing resources. Startup reports noOutput and stop fails while retaining ownership.

## Behavior boundary

These changes separate output selection and hardware controls. They do not guarantee silence on every device: process taps use mutedWhenTapped, so original audio can resume on the user-selected macOS output when the tap reader stops. Applications explicitly choosing another device can also bypass the captured default stream. If macOS and BAM select the same physical device, its hardware volume/mute remains physically shared. No full-volume acoustic safety claim is made.

The app does not set the macOS default or automatically choose a replacement listening device. No live output, volume or application-installation change was made during this implementation.

## Changes and verification

`CoreAudioEngine.swift` separates listening protection from capture topology and removes implicit fallbacks. `ConsoleViewModel.swift` preserves selection during normalization and reconciles only successful, current requests. Tests cover output persistence, default changes, absent/ambiguous outputs, unique USB rebinds, failed switches, unsupported capture controls, retained prior output guards, and empty-owner teardown refusal.

Independent review confirmed the final empty-owner guard and found no remaining P1/P2 within this contract. Full tests passed: 153 package XCTest cases (2 opt-in hardware tests skipped), 54 Swift Testing cases, 54 App tests, 5 Python collector tests and WAV analyzer self-test. Release build, Xcode static analysis and diff whitespace check passed.

## Installed verification

Installed at the user's request with the existing Developer ID, without any macOS default-output write. App PID43438; source/installed executable SHA256 both `a9e95a09ae59c629edd010d75f1d10073e04ecb8ed1ad4ac0c29fe69affd447c`.

The user-selected macOS output was Odyssey at installation and remained unchanged; BAM stayed on Razer. After protected startup, the user's pre-install100% master and unmuted state were restored. Ten subsequent snapshots stayed running on generation1/build1 with zero build/render failures or buffer-budget overruns. This verifies operation with the two separately selected devices, not acoustic peak containment.

First installation attempt safely stopped before app replacement because suspending the helper too early blocked a control handshake. Retrying with the helper paused only after control commands succeeded. Original app/preferences/config are retained in `.build-dev/independent-backup.e8DwPR`; successful-attempt backup is `.build-dev/independent-backup.waZ1NL`. Evidence: `.build-dev/independent-install-retry.log` and `.build-dev/independent-installed-health.jsonl`. This remains an unpublished local build.
