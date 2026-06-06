# Logging and diagnostics

## Categories

- `app`: app lifecycle only.
- `config`: config load, save, validation, and migration failures.
- `router`: user-visible router status, recovery, and manual restart events.
- `audio`: CoreAudio engine internals, aggregate/tap lifecycle, and health checks.
- `control`: Unix socket lifecycle, Stream Deck client state, malformed frames, and send failures.
- `streamdeck`: Stream Deck plugin process and WebSocket/UDS bridge events.

## Levels

- `debug`: normal lifecycle chatter and high-cardinality details.
- `info`: useful operational progress that is not expected on every meter tick.
- `notice`: major successful state changes.
- `warning`: recoverable malformed input, protocol mismatch, or transient failure.
- `error`: offline/terminal failure states, recovery pause, or system call failure.

Do not log meter ticks, every snapshot broadcast, or every gain update. Those paths are hot enough that logging them hides the useful signal.

## Privacy

Keep public:

- enum states and causes
- counts
- errno/status codes
- attempt numbers
- non-user-controlled operation names

Keep private:

- device UIDs
- socket paths
- config paths
- bundle IDs and app labels when they identify a user's running apps
- Stream Deck client names

## Signposts

Use signposts for performance-sensitive intervals where duration matters:

- `CoreAudioEngine.startRouter`
- `CoreAudioEngine.rebuildAggregate`
- `RouterAggregate.create`
- `ProcessTap.create`

Inspect with Instruments using the Points of Interest template or with Console filtered to subsystem `me.harke.bam`.

## Support diagnostics

`ConsoleViewModel.diagnosticsSnapshot()` returns structured state for tests and future UI. `diagnosticsReport()` returns a text report suitable for support/debug export. Keep the report compact and avoid adding hot-path samples or user-controlled labels unless privacy is reviewed first.
