# bam — Architecture Documentation

Generated architecture docs for **bam (Better Audio Mixer)**, a per-app audio
mixer/router for macOS built on the CoreAudio process-tap API.

## Contents

1. [Project Overview](1.%20Project%20Overview.md) — what bam is, stack, features,
   layout.
2. [Architecture Overview](2.%20Architecture%20Overview.md) — C4 context/container/
   component diagrams, patterns, key decisions, module breakdown.
3. [Workflow Overview](3.%20Workflow%20Overview.md) — runtime sequences: launch,
   edits, metering, recovery, remote control; data flow.

### Deep Dives

- [Audio Engine](4.%20Deep%20Dive/Audio%20Engine.md) — `CoreAudioEngine`,
  `RouterAggregate`, taps, RT boundary, health/recovery.
- [Core Model & Config](4.%20Deep%20Dive/Core%20Model%20and%20Config.md) —
  `BamConfig`, sources/mixes/sends, validation, persistence.
- [Console UI & ViewModel](4.%20Deep%20Dive/Console%20and%20ViewModel.md) — the
  menu-bar app and `ConsoleViewModel` orchestration.
- [Control Server & Protocol](4.%20Deep%20Dive/Control%20Server%20and%20Protocol.md)
  — the local NDJSON socket and wire format.
- [Stream Deck Plugin](4.%20Deep%20Dive/Stream%20Deck%20Plugin.md) — the separate
  plugin process, event mapping, rendering.

## Module map

| Module | Path | Role |
|--------|------|------|
| App | `App/` | SwiftUI console + `ConsoleViewModel` |
| BamCore | `BamKit/Sources/BamCore/` | pure model, config, rules |
| AudioEngine | `BamKit/Sources/AudioEngine/` | CoreAudio taps + aggregate |
| BamControlKit | `BamKit/Sources/BamControlKit/` | control socket server |
| BAMStreamDeck | `BamKit/Sources/BAMStreamDeck/` | Stream Deck plugin |
| BAMDriver | `BAMDriver/` | optional virtual audio driver (C, GPL) |

## See also

- [../logging-and-diagnostics.md](../logging-and-diagnostics.md) — log categories
  and support-report notes.
- Top-level [README](../../README.md) — install, build, usage.

> These docs describe the architecture as of generation. The live render path
> currently sums all sources into one hardware aggregate; the model's per-mix
> virtual-device destinations are represented and validated but fold into
> per-source gains for the live path.
