import Foundation

struct RequestMeasurement: Decodable {
    let status: String
    let reason: String?
    let finishedAt: Double
    let requestSeconds: Double
    let firstOutputSeconds: Double?
    let outputTokens: Int?
    let engineTiming: [String: Double]
    enum CodingKeys: String, CodingKey {
        case status, reason
        case finishedAt = "finished_at", requestSeconds = "request_seconds"
        case firstOutputSeconds = "first_output_seconds", outputTokens = "output_tokens"
        case engineTiming = "engine_timing"
    }
    var rate: Double? {
        guard status == "completed", let tokens = outputTokens, tokens >= 0,
              requestSeconds.isFinite, requestSeconds > 0 else { return nil }
        return Double(tokens) / requestSeconds
    }
}

struct RecentMeasurements: Decodable {
    let windowSeconds: Int
    let sampleCount: Int
    let outputTokens: Int
    let requestSeconds: Double
    enum CodingKeys: String, CodingKey {
        case windowSeconds = "window_seconds", sampleCount = "sample_count"
        case outputTokens = "output_tokens", requestSeconds = "request_seconds"
    }
    var rate: Double? {
        guard sampleCount > 0, outputTokens >= 0, requestSeconds.isFinite, requestSeconds > 0 else { return nil }
        return Double(outputTokens) / requestSeconds
    }
}

struct CollectorSnapshot: Decodable {
    let schemaVersion: Int
    let updatedAt: Double
    let storageOK: Bool
    let activeRequests: Int
    let lastCompleted: RequestMeasurement?
    let lastIssue: RequestMeasurement?
    let recent: RecentMeasurements

    func isLive(at now: Double) -> Bool { abs(now - updatedAt) <= 5 }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", updatedAt = "updated_at"
        case storageOK = "storage_ok", activeRequests = "active_requests"
        case lastCompleted = "last_completed", lastIssue = "last_issue", recent
    }
}

// Return stable English keys; the UI translates them in its selected language.
func configuredRouting(_ text: String?) -> String {
    guard let text else { return "Configured routing: cannot read Codex config" }
    var endpoint: String?
    var otherProvider = false
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { break }
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        let value = parts[1].split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if parts[0] == "openai_base_url" { endpoint = value }
        if parts[0] == "model_provider", value != "\"openai\"", value != "'openai'" { otherProvider = true }
    }
    if otherProvider { return "Configured routing: custom provider (not confirmed)" }
    if endpoint == "\"http://127.0.0.1:47831/backend-api/codex\"" || endpoint == "'http://127.0.0.1:47831/backend-api/codex'" {
        return "Configured routing: local monitor"
    }
    return "Configured routing: direct/custom · existing connections may still relay"
}

func ageLabel(_ seconds: Double, localizer l: Localizer = .english) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 { return l.format("%.0f s ago", seconds) }
    if seconds < 3600 { return l.format("%.0f min ago", floor(seconds / 60)) }
    return l.format("%.1f h ago", seconds / 3600)
}

func reasonLabel(_ reason: String?, localizer l: Localizer = .english) -> String {
    let key: String
    switch reason {
    case "missing_usage": key = "API omitted final token usage"
    case "invalid_usage": key = "API returned invalid usage"
    case "incomplete_response": key = "response incomplete (excluded)"
    case "api_error", "upstream_http_error": key = "API request failed (excluded)"
    case "unsupported_content_encoding": key = "unsupported response encoding"
    case "non_streaming_response": key = "non-streaming response"
    case "ambiguous_stream_correlation": key = "ambiguous request match (excluded)"
    case "oversize_event": key = "event exceeded observation limit"
    case "client_disconnected": key = "client disconnected before usage"
    case "upstream_connection_failed": key = "upstream connection failed"
    default: key = "stream ended before final usage"
    }
    return l.text(key)
}

struct APIReadout {
    let average: String
    let scope: String
    let active: String
    let latest: String
    let firstOutput: String
    let age: String
    let engine: String
    let quality: String
    let diagnostic: String
    let service: String

    init(snapshot: CollectorSnapshot?, legacy: Bool, now: Double, localizer l: Localizer = .english) {
        scope = l.text("All observed requests · duration-weighted · includes API waiting")
        guard let snapshot, snapshot.schemaVersion == 3 else {
            average = l.text("Recent request average: unavailable")
            active = l.text("Active requests: unknown")
            latest = l.text("Last request: no v3 measurement")
            firstOutput = l.text("First observable output delay: —")
            age = l.text("Last completed sample: —")
            engine = l.text("Server inference time: not reported")
            quality = l.text("No estimated speed substituted")
            diagnostic = l.text(legacy ? "Old collector detected · upgrade needs relay restart" : "No collector v3 metadata found")
            service = l.text("Collector v3: not confirmed running")
            return
        }
        let live = snapshot.isLive(at: now)
        if live, let rate = snapshot.recent.rate {
            average = l.format("%d s request average: ~%.0f tokens / sec (%d samples)", snapshot.recent.windowSeconds, rate, snapshot.recent.sampleCount)
        } else if live {
            average = l.format("Recent request average: no completions in last %d s", snapshot.recent.windowSeconds)
        } else {
            average = l.text("Recent average unavailable · collector heartbeat stale")
        }
        active = live ? l.format("Requests currently running: %d", snapshot.activeRequests) : l.text("Active requests: unknown (collector offline)")
        if let last = snapshot.lastCompleted, let rate = last.rate {
            latest = l.format("Last request: ~%.0f t/s · %d tokens / %.2f s", rate, last.outputTokens ?? 0, last.requestSeconds)
            firstOutput = last.firstOutputSeconds.map { l.format("Last first observable output delay: %.2f s", $0) } ?? l.text("First observable output delay: not observed")
            let old = max(0, now - last.finishedAt)
            age = l.format("Last sample completed: %@%@", ageLabel(old, localizer: l), old > 60 ? l.text(" · stale") : "")
            if let ms = last.engineTiming["engine_service_total_ms"], ms.isFinite, ms >= 0 {
                engine = l.format("Last server inference time: %.3f s (includes prefill)", ms / 1000)
            } else { engine = l.text("Server inference time: not reported/correlated") }
        } else {
            latest = l.text("Last request: no completed usage sample")
            firstOutput = l.text("First observable output delay: —")
            age = l.text("Last completed sample: —")
            engine = l.text("Server inference time: not reported")
        }
        if snapshot.recent.sampleCount == 0 { quality = l.text("No recent samples · previous result is not live speed") }
        else if snapshot.recent.outputTokens < 100 { quality = l.text("Small window (<100 output tokens) · latency-sensitive") }
        else if snapshot.recent.sampleCount < 3 { quality = l.text("Few recent samples (<3) · expect variation") }
        else { quality = l.text("Uses total output tokens / sum of request durations") }
        diagnostic = snapshot.lastIssue.map {
            l.format("Last skipped request: %@ · %@", reasonLabel($0.reason, localizer: l), ageLabel(now - $0.finishedAt, localizer: l))
        } ?? l.text("Skipped requests: none recorded")
        if !snapshot.storageOK { service = l.text("Collector storage error · history may be incomplete") }
        else if live { service = l.text("Collector v3: running · history enabled") }
        else { service = l.text("Collector v3: heartbeat older than 5 seconds") }
    }
}

struct CompactReadout {
    let menuBar: String
    let speed: String
    let subtitle: String
    let activity: String
    let delay: String
    let updated: String

    init(snapshot: CollectorSnapshot?, legacy: Bool, now: Double, localizer l: Localizer = .english) {
        guard let snapshot, snapshot.schemaVersion == 3 else {
            menuBar = "— t/s"
            speed = "—"
            subtitle = l.text(legacy ? "Restart required" : "Waiting for monitor")
            activity = l.text("Unavailable")
            delay = "—"
            updated = "—"
            return
        }
        let live = snapshot.isLive(at: now)
        if live, let rate = snapshot.recent.rate, rate.isFinite {
            let number = rate.formatted(.number.precision(.fractionLength(0)).locale(l.locale))
            menuBar = "~\(number) t/s"
            speed = l.format("≈%@ tokens/s", number)
            let count = snapshot.recent.sampleCount
            let requests = l.format(count == 1 ? "%d request" : "%d requests", count)
            let window = l.format("%@ · last %d s", requests, snapshot.recent.windowSeconds)
            subtitle = window + (snapshot.recent.outputTokens < 100 ? " · " + l.text("small sample") : "")
        } else {
            menuBar = "— t/s"
            speed = "—"
            if !live { subtitle = l.text("Monitor offline") }
            else if snapshot.activeRequests > 0 { subtitle = l.text("Measuring…") }
            else { subtitle = l.text("Waiting for Codex requests") }
        }
        if !live { activity = l.text("Unavailable") }
        else if snapshot.activeRequests > 0 { activity = l.format("%d running", snapshot.activeRequests) }
        else { activity = l.text("Idle") }
        if live, let last = snapshot.lastCompleted,
           last.finishedAt <= now, now - last.finishedAt <= Double(snapshot.recent.windowSeconds) {
            delay = last.firstOutputSeconds.map { l.format("%.1f s", $0) } ?? "—"
        } else { delay = "—" }
        if let last = snapshot.lastCompleted {
            let age = max(0, now - last.finishedAt)
            updated = age < 5 ? l.text("Just now") : ageLabel(age, localizer: l)
        } else { updated = "—" }
    }
}
