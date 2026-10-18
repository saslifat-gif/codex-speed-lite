import AppKit

func runSelfTests() throws {
    let text = #"{"schema_version":3,"updated_at":120,"storage_ok":true,"active_requests":2,"last_completed":{"status":"completed","finished_at":110,"request_seconds":3.31,"first_output_seconds":2.86,"output_tokens":21,"engine_timing":{"engine_service_total_ms":450}},"last_issue":{"status":"unavailable","reason":"missing_usage","finished_at":119,"request_seconds":1,"output_tokens":null,"engine_timing":{}},"recent":{"window_seconds":60,"sample_count":2,"output_tokens":220,"request_seconds":8}}"#
    let snapshot = try JSONDecoder().decode(CollectorSnapshot.self, from: Data(text.utf8))
    precondition(snapshot.recent.rate == 27.5)
    let view = APIReadout(snapshot: snapshot, legacy: false, now: 121)
    precondition(view.average.contains("2 samples"))
    precondition(view.latest.contains("21 tokens / 3.31 s"))
    precondition(view.age.contains("11 s ago"))
    precondition(view.engine.contains("0.450 s"))
    precondition(view.diagnostic.contains("omitted final token usage"))
    precondition(view.active.contains("2"))
    let stale = APIReadout(snapshot: snapshot, legacy: false, now: 200)
    precondition(stale.average.contains("heartbeat stale"))
    precondition(stale.age.contains("stale"))
    precondition(APIReadout(snapshot: nil, legacy: true, now: 0).diagnostic.contains("relay restart"))
    precondition(configuredRouting("# openai_base_url = fake\nmodel = 'x'\n[desktop]\nopenai_base_url='x'").contains("direct/custom"))
    precondition(configuredRouting("openai_base_url = \"http://127.0.0.1:47831/backend-api/codex\"\n[desktop]").contains("local monitor"))
    precondition(configuredRouting("model_provider = 'custom'\n").contains("custom provider"))

    let compact = CompactReadout(snapshot: snapshot, legacy: false, now: 121)
    precondition(compact.menuBar == "~28 t/s")
    precondition(compact.speed == "≈28 tokens/s")
    precondition(compact.subtitle == "2 requests · last minute · all chats")
    precondition(compact.delay == "2.86 s")
    precondition(compact.activity == "2 running")
    precondition(compact.updated == "11 s ago")
    let offline = CompactReadout(snapshot: snapshot, legacy: false, now: 200)
    precondition(offline.speed == "—" && offline.subtitle == "Monitor offline")
    precondition(CompactReadout(snapshot: nil, legacy: true, now: 0).subtitle == "Restart required")

    // Both display modes must use the same inclusive heartbeat window.
    for offset in [-6.0, -5, 0, 5, 6] {
        let now = snapshot.updatedAt + offset
        let detail = APIReadout(snapshot: snapshot, legacy: false, now: now)
        let compact = CompactReadout(snapshot: snapshot, legacy: false, now: now)
        let expectedLive = abs(offset) <= 5
        precondition(detail.service.contains("running") == expectedLive)
        precondition((compact.speed != "—") == expectedLive)
    }
    print("PASS: weighted metrics, diagnostics, routing, compact display and heartbeat boundaries")

    let row = MetricMenuRow("Codex Speed", emphasized: true)
    row.set("≈50 tokens/s")
    row.layoutSubtreeIfNeeded()
    precondition(row.frame.width == 310 && row.value.stringValue == "≈50 tokens/s")
    precondition(NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil) != nil)
    print("PASS: native menu row and monochrome system symbol")
}
