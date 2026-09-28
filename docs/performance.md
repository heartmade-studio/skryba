# Transcription performance checks

Run the injected-provider routing measurement with:

```sh
swift test --filter failoverExecutorMeasuresProviderAttemptOverhead
```

The test exercises the same sequential executor used by `AppController`: an injected Groq
failure followed by a successful local-provider result. Across 25 attempts on an Apple Silicon
Mac with Xcode's Swift Testing runner, two full-suite runs observed medians of **0.001–0.004 ms**
and p95 values of **0.002–0.016 ms**. This is
below useful wall-clock precision for the test and measures only Skryba's routing/executor
overhead. It does not include a real provider's connection timeout or model inference. The test
asserts the fallback runs and succeeds, and guards against adding a one-second delay.

## Local Whisper sample timings

On this Mac (Apple M4, Homebrew whisper.cpp 1.8.4 with Metal, `ggml-small-q5_1.bin`), synthetic
Polish speech was converted from m4a to 16 kHz mono WAV and transcribed locally:

| Synthetic clip | WAV conversion | whisper.cpp | Total |
|---:|---:|---:|---:|
| 4.76 seconds | 0.019 s | 1.077 s | 1.096 s |
| 69.09 seconds | 0.030 s | 3.081 s | 3.111 s |

These are single-host, warm-process observations, not guarantees. The samples were synthetic and
Polish-only; they do not establish accuracy or performance for other languages, hardware, model
files, or cold starts. No private audio or Cloudflare credentials were used.

Groq's current request timeout is 30 seconds, so an actual network timeout dominates the observed
local-runner time. While the request is pending, the HUD shows the active fallback stage (local
Whisper or Cloudflare) once routing advances. The 5-minute recording cap is a capture limit, not a
transcription time guarantee.
