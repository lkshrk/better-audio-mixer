# Teardown and signal-test follow-up

Implementation complete in the working tree on user authorization. Scope is the actionable findings from the [follow-on analysis](2026-09-05-follow-on-analysis.md); hardware mute protection and installed binaries remain unchanged.

## Plan

1. Strengthen ordinary native-limiter fixtures to require zero safety-guard interventions and render failures, so final clamping/silence cannot mask a failed quality check.
2. Exercise the production input mixer with both planar and interleaved output through gain retargeting and null input buffers.
3. Make router construction/closure explicitly owned by the engine. Check stop, IOProc destruction and aggregate destruction in order, retain failed stages for retry, and return failure before the engine discards state or authorizes volume restoration.
4. Make callback startup-fade memory callback-owned so a failed unregister cannot leave a dangling raw pointer. Cover build/start cleanup as well as ordinary stop/recovery.
5. Inject teardown failures into the production close path and verify successful stages are not repeated, unsafe failure does not restore/unmute, retry succeeds, and already-gone devices require positive evidence.
6. Run focused tests, full tests/analyzer, and an independent ownership/safety review. Reuse existing build caches; no live device experiments or large temporary builds.

## Verification

Implemented checked stop → IOProc destruction → aggregate destruction. Successful stages are retained as completed; failed handles remain owned for a protected retry. Only successful closure, or a direct object query establishing that the device no longer exists, permits release. The explicit `kAudioHardwareNotRunningError` stop result also allows callback cleanup; unrelated errors do not.

Router construction is resource-free and engine-owned before start. Partial start failures therefore retain an owner if cleanup also fails. Callback startup state and taps are strongly owned by the callback without retaining the router itself. All engine router releases now pass through checked close before tap-cache removal/replacement, rebuild, recovery, or checked-stop success.

Normal native-limiter fixtures now require zero guard interventions and render failures in addition to checking samples. Planar/interleaved mixer output is compared across ramp retargeting and null input buffers.

Verification:

- Targeted limiter/mixer checks: 10 tests passed.
- Targeted teardown/recovery checks: 16 tests passed, including each failing stage, retry, callback lifetime, partial startup, and retained engine ownership.
- Full `make test`: 111 package XCTest cases (2 opt-in hardware skips), 53 Swift Testing cases, and 49 App XCTest cases; zero failures.
- `xcodebuild ... analyze`: succeeded. `git diff --check`: passed.
- Independent checked-teardown review found no new actionable issue in the changed ownership/safety paths.

Test fixture compilation required correctly typed C callbacks and transfer of test resources into the engine actor; production router Sendability was not weakened. No new temporary build trees or dependencies were created.

Limits: physical hardware failures were simulated, not induced. Persistent HAL failure during final object/process shutdown may retain resources until process exit; callback-owned state prevents the prior dangling-pointer lifetime. ProcessTap's separate object-destruction status handling was not expanded in this repair. The previously documented true-peak limitation and physical latency/real-time instrumentation gaps remain outside this scope. Changes are uncommitted and not deployed.
