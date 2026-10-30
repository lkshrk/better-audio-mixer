# Contributing

Contributions are welcome: bug reports, audio routing fixes, UI improvements and
Stream Deck actions.

## Reporting issues

Open an issue with your macOS version, Mac model, output devices, the apps
involved, and what you heard versus what you expected. Include the output from
the [Diagnostics](README.md#diagnostics) section when audio routing misbehaves.

## Development

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The
project file is generated from `project.yml`; don't commit hand edits to
`bam.xcodeproj`.

```sh
make generate   # xcodegen generate
make build
make test
```

`make test-live` drives the real default output device. Quit bam and play some
audio first. It sets the system volume to 8% and restores the device state
afterwards.

See [Project layout](README.md#project-layout) for where things live. Keep
routing logic in `BamCore` free of CoreAudio so it stays unit-testable.

## Pull requests

- Fork, branch from `main`, and keep each PR focused on one change.
- Add tests for new behaviour; CI must pass.
- Include a screenshot for UI changes.
- Use [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `chore:`).

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
