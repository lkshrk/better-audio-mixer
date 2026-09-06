#!/usr/bin/env python3
"""Offline latency estimate from simultaneous stereo integer-PCM WAV captures."""

import argparse
import json
import math
import random
import tempfile
import wave
from pathlib import Path


def correlation(reference, output, lag, indices):
    count = len(indices)
    sx = sy = sxx = syy = sxy = 0.0
    for i in indices:
        x, y = reference[i], output[i + lag]
        sx += x
        sy += y
        sxx += x * x
        syy += y * y
        sxy += x * y
    denominator = (sxx - sx * sx / count) * (syy - sy * sy / count)
    return (sxy - sx * sy / count) / math.sqrt(denominator) if denominator > 1e-24 else 0.0


def rms(values):
    mean = sum(values) / len(values)
    return math.sqrt(sum((x - mean) ** 2 for x in values) / len(values))


def estimate(reference, output, rate, max_lag):
    """Bound cost: 128 reference samples per candidate, then 12 full windows."""
    ref_rms = rms(reference)
    result = {"status": "inconclusive", "sample_rate_hz": rate,
              "window_frames": len(reference), "max_lag_frames": max_lag,
              "reference_rms_dbfs": 20 * math.log10(max(ref_rms, 1e-12)),
              "lag_frames": None, "latency_ms": None}
    if ref_rms < 1e-5 or rms(output) < 1e-5:
        return dict(result, reason="silent_or_near_silent_channel")
    indices = sorted(random.Random(0).sample(range(len(reference)), min(128, len(reference))))
    scores = [abs(correlation(reference, output, lag, indices)) for lag in range(max_lag + 1)]
    # Keep distinct peaks, so a periodic probe cannot masquerade as unique timing.
    separation = max(1, round(rate * 0.001))
    candidates = []
    for lag in sorted(range(len(scores)), key=scores.__getitem__, reverse=True):
        if all(abs(lag - previous) > separation for previous in candidates):
            candidates.append(lag)
            if len(candidates) == 12:
                break
    full_indices = range(len(reference))
    refined = [(abs(correlation(reference, output, lag, full_indices)), lag)
               for lag in candidates]
    refined.sort(reverse=True)
    best_score, best_lag = refined[0]
    # Refine nearby integer lags using a denser subset, then confirm the winner.
    dense = range(0, len(reference), max(1, len(reference) // 512))
    nearby = range(max(0, best_lag - separation), min(max_lag, best_lag + separation) + 1)
    best_lag = max(nearby, key=lambda lag: abs(correlation(reference, output, lag, dense)))
    signed_score = correlation(reference, output, best_lag, full_indices)
    best_score = abs(signed_score)
    runner_up = max((score for score, lag in refined if abs(lag - best_lag) > separation), default=0.0)
    gap = best_score - runner_up
    result.update(correlation=round(best_score, 6), competing_peak_correlation=round(runner_up, 6),
                  peak_margin=round(gap, 6), polarity_inverted=signed_score < 0,
                  candidate_lag_frames=best_lag)
    if best_score < 0.6:
        return dict(result, reason="weak_match_use_broadband_probe_or_check_capture")
    if gap < 0.08:
        return dict(result, reason="ambiguous_peaks_use_nonperiodic_probe")
    if best_lag == max_lag:
        return dict(result, reason="search_upper_boundary_increase_max_lag")
    result.update(status="ok", lag_frames=best_lag, latency_ms=round(best_lag * 1000 / rate, 6))
    return result


def analyze(path, start, window_ms, max_lag_ms):
    with wave.open(str(path), "rb") as source:
        rate, width = source.getframerate(), source.getsampwidth()
        if source.getnchannels() != 2 or width not in (2, 3, 4) or source.getcomptype() != "NONE":
            raise ValueError("require stereo uncompressed signed 16/24/32-bit integer PCM WAV")
        if not 8000 <= rate <= 192000:
            raise ValueError("sample rate must be 8000..192000 Hz")
        frames, max_lag = round(rate * window_ms / 1000), round(rate * max_lag_ms / 1000)
        position = round(start * rate)
        if position + frames + max_lag > source.getnframes():
            raise ValueError("capture too short for start + window + max-lag")
        source.setpos(position)
        raw = source.readframes(frames + max_lag)
    if len(raw) != (frames + max_lag) * 2 * width:
        raise ValueError("truncated WAV data")
    scale = float(1 << (width * 8 - 1))
    left, right = [], []
    for offset in range(0, len(raw), width * 2):
        left.append(int.from_bytes(raw[offset:offset + width], "little", signed=True) / scale)
        right.append(int.from_bytes(raw[offset + width:offset + width * 2], "little", signed=True) / scale)
    result = estimate(left[:frames], right, rate, max_lag)
    result.update(file=str(path), start_seconds=start, sample_width_bits=width * 8)
    return result


def compare(before, after):
    if before["sample_rate_hz"] != after["sample_rate_hz"] or before["window_frames"] != after["window_frames"]:
        raise ValueError("comparison requires matching sample rate and analysis window")
    if before["status"] != "ok" or after["status"] != "ok":
        return {"status": "inconclusive", "reason": "both_captures_require_unambiguous_matches"}
    return {"status": "ok", "bam_added_latency_ms": round(after["latency_ms"] - before["latency_ms"], 6)}


def self_test():
    rate, count, limit = 8000, 800, 400
    rng = random.Random(42)
    reference = [rng.uniform(-0.2, 0.2) for _ in range(count + limit)]
    with tempfile.TemporaryDirectory(prefix="bam-latency-self-test-") as directory:
        captures = []
        for width, delay in ((2, 37), (3, 91), (4, 91)):
            output = [0.0] * delay + [-0.35 * x + rng.uniform(-0.001, 0.001) for x in reference]
            path = Path(directory) / f"{width}.wav"
            scale = (1 << (width * 8 - 1)) - 1
            with wave.open(str(path), "wb") as target:
                target.setparams((2, width, rate, 0, "NONE", "not compressed"))
                target.writeframes(b"".join(int(value * scale).to_bytes(width, "little", signed=True)
                                           for pair in zip(reference, output) for value in pair))
            result = analyze(path, 0, 100, 50)
            assert result["status"] == "ok" and result["lag_frames"] == delay, result
            assert result["polarity_inverted"]
            captures.append(result)
        assert compare(captures[0], captures[1])["bam_added_latency_ms"] == 6.75
        assert estimate([0.0] * count, reference, rate, limit)["reason"] == "silent_or_near_silent_channel"
        periodic = [0.2 * math.sin(i * 2 * math.pi / 40) for i in range(count + limit)]
        assert estimate(periodic[:count], periodic, rate, limit)["status"] == "inconclusive"
        unrelated = [rng.uniform(-0.2, 0.2) for _ in reference]
        assert estimate(reference[:count], unrelated, rate, limit)["status"] == "inconclusive"
        boundary = [0.0] * limit + reference
        assert estimate(reference[:count], boundary, rate, limit)["reason"].startswith("search_upper_boundary")
        assert estimate(reference[:count], reference, rate, limit)["lag_frames"] == 0
        assert compare(captures[0], {**captures[1], "status": "inconclusive"})["status"] == "inconclusive"
        try:
            compare(captures[0], {**captures[1], "sample_rate_hz": 44100})
            raise AssertionError("accepted mismatched sample rates")
        except ValueError:
            pass
        for channels, frames in ((1, 1200), (2, 10)):
            invalid = Path(directory) / "invalid.wav"
            with wave.open(str(invalid), "wb") as target:
                target.setparams((channels, 2, rate, 0, "NONE", "not compressed"))
                target.writeframes(bytes(frames * channels * 2))
            try:
                analyze(invalid, 0, 100, 50)
                raise AssertionError("accepted mono or too-short recording")
            except ValueError:
                pass
    print("PASS: PCM 16/24/32, delayed/scaled/noisy/inverted, comparison, silence, periodicity, unrelated, boundary, zero lag, rate mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", nargs="?", help="BAM-off stereo WAV: left reference, right output")
    parser.add_argument("--on", help="matching BAM-on capture for on-minus-off comparison")
    parser.add_argument("--start", type=float, default=0, help="reference window start in seconds")
    parser.add_argument("--window-ms", type=float, default=100)
    parser.add_argument("--max-lag-ms", type=float, default=250)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.capture:
        parser.error("capture is required unless --self-test is used")
    if not math.isfinite(args.start) or args.start < 0 or not 20 <= args.window_ms <= 150 or not 1 <= args.max_lag_ms <= 500:
        parser.error("require finite start >= 0, window-ms 20..150, max-lag-ms 1..500")
    try:
        result = {"capture": analyze(args.capture, args.start, args.window_ms, args.max_lag_ms)}
        if args.on:
            result["on"] = analyze(args.on, args.start, args.window_ms, args.max_lag_ms)
            result["comparison"] = compare(result["capture"], result["on"])
        print(json.dumps(result, indent=2, allow_nan=False))
    except (OSError, ValueError, wave.Error, EOFError) as error:
        parser.exit(2, json.dumps({"status": "error", "reason": str(error)}) + "\n")


if __name__ == "__main__":
    main()
