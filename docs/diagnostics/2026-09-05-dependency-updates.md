# Dependency upgrades

Completed the four proposed upgrades, one at a time, with validation between changes. No push, release publication, app installation, hardware change or playback restart was performed.

| Dependency | Previous resolved/reference version | New version | Local commit |
| --- | --- | --- | --- |
| Swift Atomics | 1.3.0 | [1.3.1](https://github.com/apple/swift-atomics/releases/tag/1.3.1) | `0668d57` |
| Yams | 5.4.0 | [6.2.2](https://github.com/jpsim/Yams/releases/tag/6.2.2) | `19e4388` |
| actions/checkout | v6 | [v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) | `57d76bc` |
| actions/setup-node | v6 | [v7.0.0](https://github.com/actions/setup-node/releases/tag/v7.0.0) | `2c834fb` |

Swift manifest lower bounds now require the selected versions; local resolution confirms Atomics 1.3.1 and Yams 6.2.2. The repository deliberately ignores `Package.resolved`; that existing policy and compatible-version ranges were preserved rather than silently changing lockfile tracking.

## Compatibility review

- Atomics 1.3.1 fixes an internal naming ambiguity for newer compilers, with no functional or public API change.
- Yams 6 supports Swift 6 concurrency. Its major-version breaking change affects associated values of `YamlError.duplicatedKeysInMapping`; no direct use was found in BAM. Configuration save/load and YAML round-trip tests passed. The version-specific open issue found concerned the static Linux SDK, not the tested macOS build.
- Checkout v7 rejects unsafe fork-head checkout in privileged workflow contexts. Automatic release gating now requires successful CI from a `push` to this repository's `main` branch. Manual dispatch retains its existing successful-CI check. The unsafe-checkout opt-out was not enabled.
- setup-node v7 uses Node 24 internally, but the Node version installed for plugin packaging remains the existing 22; those settings are independent. No npm-auth/cache migration was required by these workflows.
- All selected dependency releases are older than 48 hours. Upstream release notes and version-related issue reports were reviewed; this was not a complete security-advisory audit.

## CI toolchain coverage

Commit `c99cc78` adds a matrix with macOS 15/Xcode 16.4 and macOS 26/Xcode 26.6. CI now runs `swift test --package-path BamKit` in addition to the app tests, so package DSP/configuration tests are actually included. Release and plugin packaging select macOS 26/Xcode 26.6, matching the locally tested compiler. Both toolchain paths were checked against the current official [macOS 15](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) and [macOS 26](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) image manifests. XcodeGen 2.46.0 was already current.

## Verification

- Atomics-only full `make test`: passed.
- Yams upgrade exposed a timing-sensitive control-socket test using a fixed 100 ms delay. It failed twice and then passed without a logic change. Commit `16c0f26` replaces fixed waits in the command tests with a bounded wait for the expected mutation; assertions remain intact.
- After that correction, full `make test` passed with both runtime upgrades, including configuration round trips (113 package XCTest cases, 2 opt-in hardware skips; 53 Swift Testing cases; 49 App XCTest cases).
- Release app build with Xcode 26.6: passed.
- Universal Release Stream Deck helper build: passed; `lipo` confirms both x86_64 and arm64.
- `actionlint` 1.7.12 passed after each action change and on the final workflows. Optional ShellCheck/Pyflakes integrations were disabled because they were not part of the available validator setup.
- The actual release-gate expression passed six local cases: manual dispatch and successful trusted-main push allowed; failed CI, PR events, forks and other branches rejected.
- `git diff --check`: passed.

Hosted CI/signing/notarization has not run for these local commits. Only Xcode 26.6 was exercised locally; Xcode 16.4 coverage will run on GitHub after a push. The temporary checksum-verified actionlint download is removed after validation.

Earlier audio/logging implementation changes remain separately uncommitted. The asynchronous-test commit was staged selectively so it did not include the earlier uncommitted logging tests. Installed binaries remain unchanged by this dependency update.
