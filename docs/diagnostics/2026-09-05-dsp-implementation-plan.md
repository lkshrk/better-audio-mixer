# Audio quality implementation plan

User authorized proceeding with the research recommendations. Preserve the single aggregate and checked hardware protection; no installation or live buffer/routing changes during offline implementation.

1. Compare rendered Apple AUPeakLimiter and a bounded finite-envelope candidate against overload, delayed transparency, stereo linking, callback partition, impulse delay, recovery, invalid-input, and CPU checks. Select by evidence; keep ~1.5 ms delay initially.
2. Integrate the winner into the actual callback using preallocated storage and a shared testable processing path. Remove superseded block-envelope state. Add short sample-counted normal gain ramps and preserve silent-buffer channel positions. Validate supported Float32 layouts before rendering.
3. Coalesce ordinary gain/output targets without bypassing the serialized topology/guard path. Fix repeated-cause heartbeat backoff and preserve latest user intent during fades.
4. Separate unchanged topology/unknown health from evidence demanding recovery; never mutate taps or aggregate without the existing protection. Preserve exact channel hardware state instead of averaging restoration values.
5. Run targeted regressions, full package/app tests, analyzer, independent DSP/safety review, and bounded offline performance checks. Record actual algorithmic delay and limitations. Stable live tap membership and physical loopback/buffer tuning remain hardware experiments; do not enable an unproven alternative or silently lower the user's buffers.

Ownership: evaluate_native_limiter and evaluate_finite_limiter own temporary candidate evaluation; parent owns RouterAggregate integration and gain/mapping DSP; implement_control_targets owns App and AppTests; implement_engine_quality owns CoreAudioEngine/protocol/mock and engine tests. Shared API changes are coordinated directly.
