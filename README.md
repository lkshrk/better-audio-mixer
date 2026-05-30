# bam — Better Audio Mixer

A per-app audio mixer and router for macOS. Route any app to the output you
choose, set per-app levels, and watch live meters — all from one console.

Built on the CoreAudio process-tap API (macOS 14.4+). No kernel extension, no
SIP changes.

## Requirements

- macOS 14.4 or later
- Audio-capture permission (prompted on first launch — needed to meter and route
  other apps' audio)

## Install

### Homebrew

```sh
brew install --cask lkshrk/tap/bam
```

### Manual

Grab `bam.zip` from the [latest release](https://github.com/lkshrk/better-audio-mixer/releases/latest),
unzip, and drag `bam.app` to `/Applications`. Releases are Developer ID signed
and notarized — no Gatekeeper workaround needed.

## Build from source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode 16+.

```sh
xcodegen generate
xcodebuild -project bam.xcodeproj -scheme bam -configuration Release \
  -derivedDataPath .build build
open ".build/Build/Products/Release/bam.app"
```

Run the tests:

```sh
xcodebuild -project bam.xcodeproj -scheme bam -configuration Debug \
  -derivedDataPath .build test
```

## Project layout

| Path | What |
|------|------|
| `App/` | SwiftUI console UI + `ConsoleViewModel` |
| `BamKit/Sources/BamCore/` | Pure routing model, config, protocols |
| `BamKit/Sources/AudioEngine/` | CoreAudio engine, process taps, mixer |
| `BAMDriver/` | Virtual audio driver (C) |
| `project.yml` | XcodeGen project definition |

## License

The bam app and BamKit are MIT licensed (see [LICENSE](LICENSE)).

The virtual audio driver (`BAMDriver/`) is a derivative of
[BlackHole](https://github.com/ExistentialAudio/BlackHole) and is licensed under
GPL-3.0 (see [BAMDriver/LICENSE](BAMDriver/LICENSE) and
`BAMDriver/LICENSE.BlackHole`). It is a separate program that bam talks to over
the CoreAudio HAL, so the GPL does not extend to the MIT-licensed app.
