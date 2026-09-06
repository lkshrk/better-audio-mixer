# Follow-on analysis of the latest audio implementation

Read-only continuation after the native limiter, gain ramps, exact hardware snapshots, and control-queue changes. Two bounded subagents examined signal-test gaps and real-time/lifetime behavior; the parent traced teardown into volume restoration. No application source or hardware settings changed. Existing build/module caches were reused for one small offline probe; its source/binary and temporary result folder were removed after this report was written.

## 1. Next concrete repair: propagate teardown failures

`RouterAggregate.swift:375-387` ignores the results of `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, and `AudioHardwareDestroyAggregateDevice`, clears the handles, and frees `playedScratch`. The IOProc captures that startup-fade pointer.

`CoreAudioEngine.swift:1247-1272` performs protection, releases the router, clears its state, and returns true from `stopRouterChecked`. It cannot observe the ignored low-level teardown results. `App/ConsoleViewModel+Volume.swift:195-210` treats that true result as permission to restore volumes and mute masks.

**Confirmed source issue:** the checked-stop result proves the protection path succeeded, not that all Core Audio teardown calls succeeded. The low-level unchecked-result behavior predates the latest DSP work; the checked wrapper does not close that gap.

**Conditional consequence:** if failed teardown leaves the callback able to execute, its raw startup-ramp pointer can outlive the freed storage. The mixer/limiter are retained by the callback closure, so their ownership is stronger. Actual callback execution after teardown failure, a crash, or an audible burst was not reproduced. Some errors may mean the device is already gone, so an injected generic failure is not by itself proof of an active callback.

Recommended bounded follow-up: make teardown return meaningful outcomes, retain callback-owned state/handles until safe release is established, and propagate failure to the existing guarded recovery/restore decision. Test stop failure, callback destruction failure, aggregate destruction failure, and already-gone devices separately. Do not solve failure handling by removing hardware mute protection.

## 2. The sample-peak versus reconstructed-peak limit is demonstrated

The actual `NativePeakLimiter` wrapper was rendered offline at 8, 44.1, 48, 96, 192 and 384 kHz. Input repeated `[0.99, 0.99, -0.99, -0.99]`, with the other channel at opposite polarity and one-eighth amplitude. In the steady second half, output exactly matched the delayed input, with zero guard interventions/render failures and zero stereo proportionality error.

The corresponding steady bandlimited sinusoid at one quarter of the sample rate has amplitude:

```text
0.99 × sqrt(2) = 1.40007144, approximately +2.923 dB relative to unity
```

Thus samples below unity do not imply a reconstructed waveform below unity. This confirms the already documented sample-peak design limitation. It is not a measured DAC peak, a certified true-peak test, or evidence that the user's hardware clips. Startup/ending interpolation effects were excluded; the argument concerns the steady periodic signal.

If reconstructed-peak containment is required, define and verify that output policy explicitly. Neither a universal headroom number nor additional oversampling is selected by this counterexample alone. Keep the current hardware protection independent of that DSP decision.

## 3. Strengthen the native limiter's durable acceptance tests

`NativePeakLimiterTests.swift:32-33,40-48` checks final sample magnitudes, but the production wrapper already clamps finite output to [-1,1]. Those assertions could still pass if a future native-unit change relied heavily on final clipping. Normal finite-input fixtures do not assert that `guardedSamples` and `renderFailures` stay zero.

The new probe supplies useful positive evidence: a one-second near-Nyquist sine at amplitude 2, with the other channel at negative one-eighth amplitude, produced zero guards/failures and zero stereo proportionality error at all six rates. Observed steady sample peaks were approximately 0.99973 / 0.89114 / 0.89911 / 0.95064 / 0.97591 / 0.98806. Frequency was 0.49 times the sample rate, so these values do not isolate rate dependence at one fixed audible frequency. No new stereo or integer-delay defect was found; observed delays were 12 / 66 / 72 / 144 / 288 / 576 frames.

Recommended follow-up: normal-signal tests should check guard/failure counters as well as output, delayed transparency, and envelope behavior. Keep deliberately invalid-input/sanitization tests separate. If tiny floating-point corrections are intentionally allowed, define a numerical tolerance that cannot conceal material clipping.

## 4. Remaining callback evidence gaps

The source uses preallocated ramps, scratch/native buffers and captured arrays prepared before device start. This review found no demonstrated steady-state allocation, retain-cycle, or Swift exclusivity defect.

What remains unproven:

- Warmup renders at most 128 silent frames through the native unit, then resets. It does not instrument the first full IOProc or every larger slice.
- The production mixer fixture tests planar stride-1 output. Interleaved native-wrapper tests are separate; an actual mixer-to-wrapper interleaved fixture would strengthen integration coverage.
- Oversized-slice tests exercise fail-closed output, but do not inject an `AudioUnitRender` error. The health test constructs the failure snapshot rather than driving an error through the full callback and its atomic publication.
- The outer callback infers output layout from buffer counts/channels. Unexpected layouts or unequal frame counts can be treated as mono/truncated output rather than producing explicit format-failure evidence. No valid-HAL occurrence violating BAM's negotiated layout was demonstrated.
- Null inputs now retain channel positions correctly. Missing or reordered channel entries would need additional evidence because mapping still assumes tap-list order.

The useful next checks are controlled actual-callback fixtures for layout/failure cases, allocation/deadline instrumentation on the real I/O thread across first start and restart, then physical loopback and interruption/peak measurements. Ordinary-priority benchmark averages cannot close these gaps.

## Priority and status

1. Repair and test teardown outcome propagation/ownership before relying on checked-stop success in failure cases.
2. Strengthen normal-signal counter assertions and callback integration fixtures.
3. Decide whether sample-peak protection is sufficient; measure any proposed true-peak/headroom alternative rather than adding latency automatically.
4. Collect actual I/O-thread and hardware evidence before lowering buffers or claiming minimum stable latency.

The prior successful 102 package XCTest / 53 Swift Testing / 49 App test results remain valid for the code they exercised; this analysis did not rerun or broaden that suite. It adds a bounded signal probe and identifies missing evidence. It does not invalidate the demonstrated memory fix, delayed transparency, gain smoothing, or calibrated restoration tests, and makes no deployment change.
