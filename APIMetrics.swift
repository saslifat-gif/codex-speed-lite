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

func configuredRouting(_ text: String?) -> String {
    guard let text else { return "Configured routing: cannot read Codex config" }
    var endpoint: String?
    var otherProvider = false
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { break } // Only inspect top-level keys, never secret sections.
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

func ageLabel(_ seconds: Double) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 { return String(format: "%.0f s ago", seconds) }
    if seconds < 3600 { return String(format: "%.0f min ago", floor(seconds / 60)) }
    return String(format: "%.1f h ago", seconds / 3600)
}

func reasonLabel(_ reason: String?) -> String {
    switch reason {
    case "missing_usage": return "API omitted final token usage"
    case "invalid_usage": return "API returned invalid usage"
    case "incomplete_response": return "response incomplete (excluded)"
    case "api_error", "upstream_http_error": return "API request failed (excluded)"
    case "unsupported_content_encoding": return "unsupported response encoding"
    case "non_streaming_response": return "non-streaming response"
    case "ambiguous_stream_correlation": return "ambiguous request match (excluded)"
    case "oversize_event": return "event exceeded observation limit"
    case "client_disconnected": return "client disconnected before usage"
    case "upstream_connection_failed": return "upstream connection failed"
    default: return "stream ended before final usage"
    }
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

    init(snapshot: CollectorSnapshot?, legacy: Bool, now: Double) {
        scope = "All observed requests · duration-weighted · includes API waiting"
        guard let snapshot, snapshot.schemaVersion == 3 else {
            average = "Recent request average: unavailable"
            active = "Active requests: unknown"
            latest = "Last request: no v3 measurement"
            firstOutput = "First observable output delay: —"
            age = "Last completed sample: —"
            engine = "Server inference time: not reported"
            quality = "No estimated speed substituted"
            diagnostic = legacy ? "Old collector detected · upgrade needs relay restart" : "No collector v3 metadata found"
            service = "Collector v3: not confirmed running"
            return
        }
        let live = snapshot.isLive(at: now)
        if live, let rate = snapshot.recent.rate {
            average = String(format: "%d s request average: ~%.0f tokens / sec (%d samples)", snapshot.recent.windowSeconds, rate, snapshot.recent.sampleCount)
        } else {
            average = live ? "Recent request average: no completions in last \(snapshot.recent.windowSeconds) s" : "Recent average unavailable · collector heartbeat stale"
        }
        active = live ? "Requests currently running: \(snapshot.activeRequests)" : "Active requests: unknown (collector offline)"
        if let last = snapshot.lastCompleted, let rate = last.rate {
            latest = String(format: "Last request: ~%.0f t/s · %d tokens / %.2f s", rate, last.outputTokens ?? 0, last.requestSeconds)
            firstOutput = last.firstOutputSeconds.map { String(format: "Last first observable output delay: %.2f s", $0) } ?? "First observable output delay: not observed"
            let old = max(0, now - last.finishedAt)
            age = "Last sample completed: \(ageLabel(old))\(old > 60 ? " · stale" : "")"
            if let ms = last.engineTiming["engine_service_total_ms"], ms.isFinite, ms >= 0 {
                engine = String(format: "Last server inference time: %.3f s (includes prefill)", ms / 1000)
            } else { engine = "Server inference time: not reported/correlated" }
        } else {
            latest = "Last request: no completed usage sample"
            firstOutput = "First observable output delay: —"
            age = "Last completed sample: —"
            engine = "Server inference time: not reported"
        }
        if snapshot.recent.sampleCount == 0 { quality = "No recent samples · previous result is not live speed" }
        else if snapshot.recent.outputTokens < 100 { quality = "Small window (<100 output tokens) · latency-sensitive" }
        else if snapshot.recent.sampleCount < 3 { quality = "Few recent samples (<3) · expect variation" }
        else { quality = "Uses total output tokens / sum of request durations" }
        diagnostic = snapshot.lastIssue.map { "Last skipped request: \(reasonLabel($0.reason)) · \(ageLabel(now - $0.finishedAt))" } ?? "Skipped requests: none recorded"
        if !snapshot.storageOK {
            service = "Collector storage error · history may be incomplete"
        } else if live {
            service = "Collector v3: running · history enabled"
        } else {
            service = "Collector v3: heartbeat older than 5 seconds"
        }
    }
}

struct CompactReadout {
    let menuBar: String
    let speed: String
    let subtitle: String
    let activity: String
    let delay: String
    let updated: String

    init(snapshot: CollectorSnapshot?, legacy: Bool, now: Double) {
        guard let snapshot, snapshot.schemaVersion == 3 else {
            menuBar = "— t/s"
            speed = "—"
            subtitle = legacy ? "Restart required" : "Waiting for monitor"
            activity = "Unavailable"
            delay = "—"
            updated = "—"
            return
        }
        let live = snapshot.isLive(at: now)
        if live, let rate = snapshot.recent.rate, rate.isFinite {
            let number = rate.formatted(.number.precision(.fractionLength(0)))
            menuBar = "~\(number) t/s"
            speed = "≈\(number) tokens/s"
            let count = snapshot.recent.sampleCount
            subtitle = "\(count) \(count == 1 ? "request" : "requests") · last minute · \(snapshot.recent.outputTokens < 100 ? "small sample" : "all chats")"
        } else {
            menuBar = "— t/s"
            speed = "—"
            if !live { subtitle = "Monitor offline" }
            else if snapshot.activeRequests > 0 { subtitle = "Measuring…" }
            else { subtitle = "No recent requests" }
        }
        if !live { activity = "Unavailable" }
        else if snapshot.activeRequests > 0 { activity = "\(snapshot.activeRequests) running" }
        else { activity = "Idle" }
        delay = snapshot.lastCompleted?.firstOutputSeconds.map { String(format: "%.2f s", $0) } ?? "—"
        if let last = snapshot.lastCompleted {
            let age = max(0, now - last.finishedAt)
            updated = age < 5 ? "Just now" : ageLabel(age)
        } else { updated = "—" }
    }
}
