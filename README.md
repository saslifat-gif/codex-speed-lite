# Codex Speed Lite 3 — metadata-only request monitor

A native macOS menu-bar app with a loopback-only, metadata-only API monitor. Version 3 retains individual request measurements instead of overwriting a single result. Credentials, usage history, local backups, environments, and build products are excluded from version control.

## Source checkout

Requires Apple Silicon, macOS 14 or later, Xcode Command Line Tools, and Python 3.11 or later. The current app expects its helper checkout at `~/.local/src/codex-speed-lite`.

```sh
git clone https://github.com/saslifat-gif/codex-speed-lite.git ~/.local/src/codex-speed-lite
cd ~/.local/src/codex-speed-lite
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest discover -v
zsh build.sh
```

After closing any existing menu-bar display, copy `build/Codex Speed Lite.app` into `~/Applications/` and open it. Building or opening the display does not enable API routing automatically; see activation below. No API keys belong in this repository.

## Simplification 3.1.1

The unused whole-turn log reader is no longer compiled; local backups are not part of this repository. Current Swift checks live in `SelfTests.swift`, rather than mixing test fixtures into the display models and application entry point. The display shares one heartbeat-freshness check and no longer builds an unused second menu-bar label. HTTP observation always detects SSE/JSON framing, removing an unused mode switch. Request correlation, history format, aggregation, native menu, and icons are unchanged. The test command below runs the current API monitor's tests; it does not run the retired whole-turn reader tests.

## Compact native display 3.1

The primary menu uses the system menu material and SF fonts, with a compact two-column header (`Codex Speed` / approximate request tokens/sec), a one-line sample summary, and only Response delay, Activity and Last measured underneath. Technical readouts, routing, diagnostics, history and restore controls live in the Details submenu. Menu-bar icon is the native monochrome `speedometer` SF Symbol, which follows the system appearance; the app icon is a matching graphite gauge on a flat silver rounded tile. No custom glass effect, decorative shadows, or coloured status glyphs are drawn. The collector and its formulas are unchanged by this display-only update.

## Measurement contract

The main menu-bar number is a **60-second duration-weighted request-throughput average**:

`sum(API output tokens) / sum(API request durations)`

The cohort is successful usage-bearing requests **completed within the last 60 seconds**. It is not an arithmetic mean of individual rates and not total tokens divided by 60. Durations of concurrent requests are summed, so parallelism does not masquerade as faster single-stream generation. All observed chats and subagents are included; there is no claim that the result belongs to the foreground chat. Hidden reasoning is included in API output totals.

A request begins before forwarding its HTTP request or WebSocket `response.create`. Completion timing uses the response-event receipt timestamp captured before awaiting downstream forwarding, not a later parsing/storage timestamp. It includes API/network waiting, prefill, and inference. It excludes time between API calls and local tool execution. Proxy backpressure, packet buffering, and client-observation limits still apply; this is not a server-internal benchmark.

First observable output delay is separate. It recognizes nonempty text, reasoning text/summary, function arguments, and custom-tool input deltas. A chunk is never assumed to be one token. We do not subtract this delay from total time to time hidden reasoning tokens or claim pure decode speed.

The last completed sample remains available alongside the rolling average and is labelled with its age. The average clears once its cohort expires; the app does not silently substitute an old single-request result as a current average. Small/few-sample warnings are explicit heuristics, not confidence intervals.

## Correlation and optional server timing

Each request has a new local random measurement ID. Upstream response IDs are kept only in memory for matching. Separate sockets cannot overwrite one another. Responses with IDs can complete out of order once bound. Warmups (`generate: false`) are tracked for correlation but excluded from measurements. Ambiguous multi-request matches are explicitly skipped, not guessed.

`responsesapi.websocket_timing` is inspected even after completion. Only server fields with an explicit matching response ID are attached. Late timing creates a keyed revision of the same record, not an extra usage sample. The display can show server-reported engine service time when supplied, labelled as including prefill. Missing or unmatched engine timing stays unavailable. Pure generation-only speed is not established.

Partial, cancelled, failed, missing-usage, malformed or unsupported responses never receive fabricated token counts. Skipped requests carry safe reason codes. Server timing may not be present on your account/client/backend; mock coverage does not prove that live responses supply it.

## Files and privacy

- Source collector: `collector.py`
- Streaming relay: `api_monitor.py`
- App projection/readout: `APIMetrics.swift` and `main.swift`
- Snapshot: `~/.local/share/codex-speed-lite/api-metrics.json`
- Daily append-only metadata history: `~/.local/share/codex-speed-lite/history-v3/YYYY-MM-DD.jsonl`
- Launch agent: `~/Library/LaunchAgents/local.codex.speedlite.relay.plist`

Snapshot schema is version 3 and includes an every-second heartbeat, running-request count, last successful sample, latest skipped request/reason, recent weighted aggregate and diagnostic counts. Daily history stores terminal records and keyed revisions for late timing; consumers must upsert by local `sample_id`/`revision`, not sum every journal line. On restart, the collector recovers the newest record per local ID from today/yesterday. In-memory records are capped at 20,000; daily journals are not automatically deleted. A day larger than 64 MiB is not recovered automatically. No historical timings before v3 activation can be recreated from this journal.

All persisted fields are allowlisted measurement metadata: local IDs, timestamps, durations, status/reason codes, numeric token/event counts, and allowlisted numeric server timings. Prompts, generated text, authentication headers, credentials, provider response IDs and full payloads are not saved. Files are owner-readable (0600). Storage failures do not deliberately terminate traffic forwarding; the UI warns history may be incomplete. Recovery validates records and deduplicates revisions.

The relay listens only on `127.0.0.1:47831` and forwards only `/backend-api/codex/…` to the fixed HTTPS origin `https://chatgpt.com`. It does not load auth.json, install a TLS interception certificate, switch accounts, issue independent model calls, or retry requests. Existing credentials are forwarded in memory. HTTP compressed request bytes stay unchanged. Identity/gzip/deflate responses can be observed while response bytes are forwarded unchanged. The observer identifies valid SSE/JSON framing from a bounded in-memory prefix rather than trusting optional/mislabelled Content-Type headers: the live backend did not consistently label SSE as text/event-stream. Non-streaming JSON with final usage is supported, without fabricating a first-output delay. Unsupported encodings/formats get a diagnostic instead of a guessed speed. Safe HTTP status and inferred format labels are saved as metadata; raw headers and body prefixes are not. Access/stdout/stderr logging is disabled.

## Upgrade activation — may interrupt active requests

Building or replacing the display does not upgrade an already-running relay process. Existing Codex connections can continue using the old relay even after the configuration file is restored to direct mode. Do not infer active routing solely from the current file. The v3 display identifies legacy metadata, stale heartbeats, and the configured route separately.

After explicit approval to interrupt/reconnect active relay connections:

```
.venv/bin/python control.py restart --confirm-interrupt
.venv/bin/python control.py health
```

This restarts only the relay and leaves Codex routing configuration unchanged. `enable` refuses to silently restart a legacy relay. No live-upgrade claim is made before v3 health is confirmed.

To enable future Codex connections through the relay:

```
.venv/bin/python control.py enable
```

This backs up config.toml and prepends a marked `openai_base_url` override, without changing model/provider/account/auth mode. Restart Codex’s persistent app-server daemon after its work is safe to interrupt; merely closing a window may leave the daemon running with old settings. Enabling/configuring/restarting does not generate a model response; normal subsequent usage is measured. Verify a normal request updates v3 metadata before treating the upgrade as end-to-end validated.

## Restore direct mode

Use **Restore direct connection…** in the menu or:

```
.venv/bin/python control.py disable
```

Then restart Codex when safe. The relay stays up to preserve existing connections. This removes only the exact monitor-owned config block, preserving unrelated edits. After Codex has restarted in direct mode, optionally unload the relay:

```
launchctl bootout gui/$(id -u)/local.codex.speedlite.relay
```

Remove its launch-agent plist if you do not want it started on login. Quitting the menu-bar display alone intentionally does not stop the relay.

## Build and tests

```
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest -v test_collector test_api_monitor test_control
zsh build.sh
```

Tests use synthetic events and loopback upstreams, never paid model calls. Coverage includes weighted arithmetic/window expiry, history survival and recovery, concurrent/out-of-order requests, warmups, custom tools, missing usage and diagnostics, receipt-time accounting, late engine timing without double counting, privacy/permissions, byte-split SSE, gzip responses, compressed request fidelity, streaming without full-response buffering, routing restrictions, config rollback, and refusal to implicitly restart a legacy relay. The current tests assert corrected collector behaviour rather than preserving the old monitor’s limitations.

Swift self-tests cover average arithmetic, sample counts/age, correlation-derived server timing display, diagnostics, configured routing, and old/offline collector states. Live SSE compatibility has been checked locally, but this does not prove every backend event type, optional server timing availability, or latency overhead. Personal measurements and their history remain local and are not included in the repository.

## Method references reviewed

- vLLM benchmark metrics: https://github.com/vllm-project/vllm/blob/main/vllm/benchmarks/serve.py — TTFT, TPOT and aggregate throughput are separate metrics.
- NVIDIA GenAI-Perf parser: https://github.com/triton-inference-server/perf_analyzer/blob/main/genai-perf/genai_perf/profile_data_parser/llm_profile_data_parser.py — request latency, first-token latency, token timing and throughput are reported separately.
- Codex telemetry: https://github.com/openai/codex/blob/main/codex-rs/otel/src/events/session_telemetry.rs — optional response WebSocket timing metrics.

Benchmark formulas that assume visible tokens cannot blindly be applied to Codex’s hidden reasoning totals.
