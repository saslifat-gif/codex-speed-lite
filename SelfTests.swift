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
    precondition(offline.delay == "—", "A stale sample must not look like a current response delay")
    let idleSnapshot = CollectorSnapshot(schemaVersion: 3, updatedAt: 200, storageOK: true,
        activeRequests: 0, lastCompleted: snapshot.lastCompleted, lastIssue: nil,
        recent: RecentMeasurements(windowSeconds: 60, sampleCount: 0, outputTokens: 0, requestSeconds: 0))
    let idle = CompactReadout(snapshot: idleSnapshot, legacy: false, now: 200)
    precondition(idle.delay == "—" && idle.subtitle == "Waiting for Codex requests")
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
    let resource = Bundle.main.resourceURL!.appendingPathComponent("zh-Hans.lproj/Localizable.strings")
    precondition(FileManager.default.fileExists(atPath: resource.path), "Chinese interface resources must be bundled")
    try runLanguageTests(snapshot)
}

func runLanguageTests(_ snapshot: CollectorSnapshot) throws {
    _ = NSApplication.shared
    precondition(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
    precondition(InterfaceLanguage.system.resolved(preferredLanguages: ["en-US", "zh-Hans"]) == "en")
    precondition(InterfaceLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == "en")
    let chinese = Localizer(language: .simplifiedChinese)
    precondition(chinese.text("Details") == "详细信息")
    let compact = CompactReadout(snapshot: snapshot, legacy: false, now: 121, localizer: chinese)
    precondition(compact.speed == "≈28 token/秒")
    precondition(compact.subtitle == "2 个请求 · 最近一分钟 · 所有对话")
    precondition(compact.delay == "2.86 秒" && compact.updated == "11 秒前")
    precondition(compact.activity == "2 个请求运行中")
    let detail = APIReadout(snapshot: snapshot, legacy: false, now: 121, localizer: chinese)
    precondition(detail.average.contains("2 个样本") && detail.diagnostic.contains("API 未返回最终 token 用量"))
    precondition(CompactReadout(snapshot: snapshot, legacy: false, now: 200, localizer: chinese).subtitle == "监测器离线")

    let suite = "local.codex.speedlite.language-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    precondition(InterfaceLanguage.saved(in: defaults) == .system)
    InterfaceLanguage.simplifiedChinese.save(in: defaults)
    precondition(InterfaceLanguage.saved(in: defaults) == .simplifiedChinese)

    // Exercise the real menu action without changing the user's actual preferences.
    let display = App(preferences: defaults)
    display.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    display.timer?.invalidate()
    defer { NSStatusBar.system.removeStatusItem(display.item) }
    display.latestSnapshot = CollectorSnapshot(
        schemaVersion: 3, updatedAt: Date().timeIntervalSince1970, storageOK: true,
        activeRequests: snapshot.activeRequests, lastCompleted: snapshot.lastCompleted,
        lastIssue: snapshot.lastIssue, recent: snapshot.recent)
    display.renderSnapshot()
    precondition(display.delay.label.stringValue == "响应延迟")
    precondition(display.heading.value.stringValue == "≈28 token/秒")
    let englishOption = display.languageMenu.items.first { $0.representedObject as? String == "en" }!
    display.changeLanguage(englishOption)
    precondition(display.delay.label.stringValue == "Response delay")
    precondition(display.heading.value.stringValue == "≈28 tokens/s")
    precondition(englishOption.state == .on && InterfaceLanguage.saved(in: defaults) == .english)
    let chineseOption = display.languageMenu.items.first { $0.representedObject as? String == "zh-Hans" }!
    display.changeLanguage(chineseOption)
    precondition(display.more.title == "详细信息" && chineseOption.state == .on && englishOption.state == .off)
    precondition(display.reconnect.title == "重新连接 Codex 桌面应用…" && display.reconnect.isEnabled)
    precondition(display.rows[9].title.contains("API 未返回最终 token 用量"))
    precondition(InterfaceLanguage.saved(in: defaults) == .simplifiedChinese)
    print("PASS: Chinese readouts, system selection, saved preference, and immediate bidirectional menu switching")
}
