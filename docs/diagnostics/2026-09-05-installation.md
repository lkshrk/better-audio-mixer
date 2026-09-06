# Local installation status

## Current: new app and helper installed

The user approved the Razer default-output change and the controlled low-level test. The new signed app is now installed and running as PID 7483; its installed executable SHA-256 matches the Release build:

`1405c4469e6a7fe8de0ef5a289b793e4630aa63ef522710f2c75452282dda2b9`

macOS default output and BAM output now both use `AppleUSBAudioEngine:Unknown Manufacturer:Razer BlackShark V2 Pro 2.4:O001000007:2`. Startup logged a live aggregate with five taps. Control-socket verification received 152 live meter frames in approximately five seconds and confirmed unmuted master state at 0.121502034 (hardware quantization of the requested 0.12). Recent log inspection found no matching router failure/recovery events. App and helper remained running.

The original app remains backed up at `.build-dev/install-backup.4QPbBp/bam.app` while subjective headset quality confirmation is pending. Redundant staging/backup copies were removed. The final replacement did not pause the old audio callback: it confirmed mute through the original app, protected the low hardware level, replaced the process without its old stock-volume exit handler, switched the authorized default, then started the new app muted before enabling low-level playback.

These checks establish that the new binary is actually running on the selected hardware; they are not acoustic loopback, true-peak certification, or a long-duration stability test.

## Preparation and earlier attempts

- Stream Deck helper: installed, restarted and stable as PID 86044. Built/installed SHA-256 matched `81cb73446f0102b29fb1936763e9e1201eb8b0f3d5afe646147504235472bc13`. Immediate physical footprint: 10.2M (peak 10.5M), replacing the former multi-GB process. This is a startup observation, not a long-duration soak.
- App: Release build succeeded in the existing `.build-dev` directory. Signed and verified using the same Developer ID team as the installed app (`H7BGVMC6L6`, identifier `me.harke.bam`). The running `/Applications/bam.app` has not yet been replaced or restarted.
- Actual hardware preflight: BAM routes to Razer BlackShark V2 Pro 2.4; macOS default is Odyssey G60SD. The display exposes no readable/writable volume or mute elements; Razer output has both. The new checked guard cannot protect the current display capture device.
- Pending user decision: authorize making the existing BAM output (Razer) the macOS default, or retain the current default. No system default/volume/mute change was made while awaiting that decision.

## Subsequent recovery

The user approved the Razer default switch. The installation safety check then stopped before replacing the app: the headset quantized a requested 0.12 level to 0.121502034, exceeding the install probe's overly narrow 0.121 limit. The probe now permits the verified quantized level below 0.13. The macOS default was not switched and the app bundle was not replaced.

The user reported creaking/distortion during this interrupted attempt. The original app was restarted (PID 83168), its fallback output was switched back to the original Razer route, and hardware probes stopped because they can trigger the old app's lifecycle rebuilds. The new limiter/app was never active. Subjective recovery is awaiting user confirmation. The rebuilt app remains staged/signed; helper installation remains completed.

The user subsequently confirmed proceeding with the controlled test; the successful installation above supersedes that earlier pending state.

The user requested installation, so the unaffected helper installation completed. App replacement/restart is held at the demonstrated hardware compatibility/safety boundary, not a build or signing failure.
