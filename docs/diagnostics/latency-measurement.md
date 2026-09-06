# Repeatable offline BAM latency comparison

## Collect processing diagnostics separately

After installing a build with the diagnostics endpoint, collect ordinary playback telemetry without starting/stopping audio or changing a device setting:

```sh
python3 scripts/collect-audio-diagnostics.py --samples 30 --interval 1 > audio-diagnostics.jsonl
```

The collector connects to the existing local control socket, performs the normal handshake, and requests `{"t":"diagnostics"}`. It keeps draining pushed meter messages between requests so it does not stall the control server. An older build that lacks the endpoint produces a bounded timeout with an update message. No app is auto-launched. `audio: null` means no measurement is available, not zero latency.

The same counters appear in BAM's copied diagnostics report. They cover processed callbacks, frame sizes, elapsed processing time/nominal-buffer ratios, estimated output-host-time misses, limiter input/guard/failure events, and aggregate build counts/duration. They are field-wise approximate snapshots. Callback statistics reset per aggregate generation; engine build totals span the process lifetime. Build duration excludes teardown and the complete protected mute/fade interval. These counters do not replace the recording measurement below or establish acoustic dropouts.

An idle engine may report zero initialized counters with `isRunning: false`; timing fields are meaningful only when `callbackCount` is nonzero. A retained stopped generation can have historical timing values, so compare generation and running state before interpreting changes.

Collector self-check: `python3 -B scripts/tests/test_collect_audio_diagnostics.py`.

## Offline analyzer self-check

`python3 scripts/analyze-audio-latency.py --self-test` runs synthetic checks without playing audio or touching devices. Temporary WAVs are removed automatically. Python 3 standard library only.

## Capture contract

Record **two simultaneous channels in one PCM WAV**:

- Left: a dry timing reference, captured before the path being measured.
- Right: the same nonperiodic broadband probe after the output path.

Both channels must share the recording clock. Supported input: stereo, uncompressed signed integer PCM, 16/24/32 bits, 8–192 kHz. Float WAV is not supported. Separate playback and recording files with unrelated start times are not a valid substitute. The output must arrive at or after the reference, within the requested search range.

Use a safe, low test level and preserve BAM's mute guards. Do not disable protection or raise output to maximum to measure timing. Choose a nonrepeating noise burst or broadband transient sequence; continuous tones and repeated clicks can produce ambiguous delays. Capture enough material after the selected reference window to cover the maximum lag. Do not clip either channel; this tool does not assess distortion or identify dropouts.

For an electrical loopback, use a suitable line output and compatible line input with safe levels. The result includes the measured output/input conversion and recording path. Do not connect a powered speaker output to a microphone input.

For the actual wireless headset, acoustic pickup measures the complete headset path plus sound propagation, microphone processing, and capture latency. A headset microphone may enable a different Bluetooth profile or voice processing, changing the path under test. A motherboard line-output measurement does not establish wireless-headset latency. Keep microphone placement, transport/profile, input path, buffer settings, sample rate, output level, and probe unchanged between BAM-off and BAM-on runs.

## Analyze

```sh
python3 scripts/analyze-audio-latency.py bam-off.wav --start 1 --max-lag-ms 250
python3 scripts/analyze-audio-latency.py bam-off.wav --on bam-on.wav --start 1 --max-lag-ms 250
```

The default reference window is 100 ms. Select a window containing the probe using `--start`; each capture may have a different probe waveform but both must contain useful broadband material at that position. Reference windows are bounded to 20–150 ms; the forward lag search is bounded to 1–500 ms. Repeat measurements at several start positions and with multiple captures. Preserve the JSON outputs, capture files, and hardware/settings notes. Compare median and spread of successful runs, not just the smallest observed number.

Output is readable JSON. `lag_frames` is the integer number of recording samples by which right follows left; `latency_ms` converts it to time. `bam_added_latency_ms` is BAM-on minus BAM-off, **only meaningful with unchanged physical capture conditions**. A negative difference can reflect measurement variation or a changed path. The script checks matching sample rates and analysis-window sizes, but cannot check physical conditions.

`status: inconclusive` leaves latency null for silence, weak matches, ambiguous peaks, or a match at the upper search boundary. Inspect `reason`; choose better probe material or increase the bound when appropriate. `candidate_lag_frames` on an inconclusive result is diagnostic, not an accepted measurement. Invalid WAVs/configuration return an error and exit status 2. Inconclusive valid captures return JSON with exit status 0, so automation must check `status`.

## Confidence and limits

The estimator searches every integer lag using 128 deterministic dispersed reference samples, checks up to 12 distinct candidate peaks against the full window, then refines the winning neighborhood. It does not decimate the waveform. Memory and work are bounded by the configured window, rate, and lag limits rather than the recording duration.

The reported absolute normalized correlation is insensitive to constant scaling and polarity inversion. Acceptance requires correlation ≥0.6 and a margin ≥0.08 over competing checked peaks separated by more than 1 ms. These are conservative heuristics, **not statistical confidence or proof of the globally best full-window match**. Strong filtering, narrowband signals, echo, periodicity, clock drift, or changing delay can make the estimate inconclusive or biased; use independent repeated captures and short windows. Integer-sample resolution is not equivalent to hardware accuracy. No separate DAC, RF, acoustic, or software latency is inferred.

This provides a repeatable analysis step; it does not capture audio, measure callback deadline misses, prove dropout-free playback, or replace listening at matched levels. No hardware measurements have been made by this tool's synthetic tests.
