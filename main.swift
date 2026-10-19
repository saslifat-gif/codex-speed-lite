import AppKit

final class MetricMenuRow: NSView {
    let label: NSTextField
    let value: NSTextField

    init(_ title: String, emphasized: Bool = false, secondary: Bool = false, height: CGFloat = 26) {
        label = NSTextField(labelWithString: title)
        value = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: height))
        for field in [label, value] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: secondary ? 11 : 13, weight: emphasized ? .semibold : .regular)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(_ text: String) { value.stringValue = text; setAccessibilityValue(text) }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let worker = DispatchQueue(label: "local.codex.speedlite.metadata", qos: .utility)
    let menu = NSMenu()
    let details = NSMenu()
    let languageMenu = NSMenu()
    let more = NSMenuItem()
    let languageItem = NSMenuItem()
    let reconnect = NSMenuItem()
    let history = NSMenuItem()
    let method = NSMenuItem()
    let restore = NSMenuItem()
    let quit = NSMenuItem()
    let rows = (0..<12).map { _ in NSMenuItem(title: "—", action: nil, keyEquivalent: "") }
    let heading = MetricMenuRow("Codex Speed", emphasized: true, height: 29)
    let subtitle = MetricMenuRow("", secondary: true, height: 21)
    let delay = MetricMenuRow("")
    let activity = MetricMenuRow("")
    let updated = MetricMenuRow("")
    let preferences: UserDefaults
    var language: InterfaceLanguage
    var latestSnapshot: CollectorSnapshot?
    var latestLegacy = false
    var latestRoute = "Configured routing: cannot read Codex config"
    var item: NSStatusItem!
    var timer: Timer?
    var busy = false
    var reconnecting = false
    var showOnLoad = CommandLine.arguments.contains("--show")

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        language = InterfaceLanguage.saved(in: preferences)
        super.init()
    }

    func addView(_ view: NSView) {
        let row = NSMenuItem()
        row.view = view
        menu.addItem(row)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for submenu in [menu, details, languageMenu] {
            submenu.autoenablesItems = false
            submenu.delegate = self
        }
        addView(heading)
        addView(subtitle)
        menu.addItem(.separator())
        addView(delay)
        addView(activity)
        addView(updated)
        menu.addItem(.separator())
        more.submenu = details
        menu.addItem(more)
        languageItem.submenu = languageMenu
        details.addItem(languageItem)
        for choice in InterfaceLanguage.allCases {
            let option = NSMenuItem(title: "", action: #selector(changeLanguage), keyEquivalent: "")
            option.representedObject = choice.rawValue
            option.target = self
            languageMenu.addItem(option)
        }
        reconnect.action = #selector(reconnectDesktop)
        reconnect.target = self
        details.addItem(reconnect)
        details.addItem(.separator())
        for row in rows {
            row.isEnabled = false
            details.addItem(row)
        }
        details.addItem(.separator())
        history.action = #selector(openHistory)
        history.target = self
        details.addItem(history)
        method.action = #selector(openMethod)
        method.target = self
        details.addItem(method)
        details.addItem(.separator())
        restore.action = #selector(restoreDirect)
        restore.target = self
        details.addItem(restore)
        quit.action = #selector(quitApp)
        quit.target = self
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        if let icon = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Codex Speed") {
            let configured = icon.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? icon
            configured.isTemplate = true
            configured.size = NSSize(width: 16, height: 16)
            item.button?.image = configured
            item.button?.imagePosition = .imageLeading
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        applyLanguage()
        renderSnapshot()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }

    func applyLanguage() {
        let l = Localizer(language: language)
        for (row, key) in [(delay, "Response delay"), (activity, "Activity"), (updated, "Last measured")] {
            row.label.stringValue = l.text(key)
        }
        for (option, key) in [(more, "Details"), (languageItem, "Language / 语言"),
                              (reconnect, "Reconnect Codex Desktop…"),
                              (history, "Open History…"), (method, "About Measurements…"),
                              (restore, "Restore Direct Connection…"), (quit, "Quit Codex Speed")] {
            option.title = l.text(key)
        }
        for option in languageMenu.items {
            guard let raw = option.representedObject as? String, let choice = InterfaceLanguage(rawValue: raw) else { continue }
            switch choice {
            case .system: option.title = l.text("System Default")
            case .english: option.title = "English"
            case .simplifiedChinese: option.title = "简体中文"
            }
            option.state = choice == language ? .on : .off
        }
        heading.toolTip = l.text("Recent request throughput: total output tokens divided by total request duration. Includes reasoning and API waiting; excludes local tools. Not pure generation speed.")
        subtitle.toolTip = l.text("Completed requests in the last minute, across all observed chats and subagents. Concurrent request durations are summed.")
            + "\n" + l.text("If Codex is working but nothing is measured, use Details → Reconnect Codex Desktop…")
        delay.toolTip = l.text("Time to the last completed request’s first observable text, reasoning-summary, or tool-input output. Hidden reasoning may come earlier.")
        updated.toolTip = l.text("Age of the last completed sample, not the snapshot file.")
        quit.toolTip = l.text("The relay stays running so active Codex connections are not interrupted.")
        item.button?.setAccessibilityLabel(l.text("Codex Speed. Recent request throughput."))
    }

    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = InterfaceLanguage(rawValue: raw) else { return }
        language = choice
        choice.save(in: preferences)
        applyLanguage()
        renderSnapshot()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc func openMethod() {
        let name = language.resolved() == "zh-Hans" ? "README.zh-CN.md" : "README.md"
        NSWorkspace.shared.open(home.appendingPathComponent(".local/src/codex-speed-lite/\(name)"))
    }
    @objc func openHistory() {
        let folder = home.appendingPathComponent(".local/share/codex-speed-lite/history-v3")
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { openMethod() }
    }

    func runControl(_ command: String, completion: @escaping (Bool) -> Void) {
        let task = Process()
        task.executableURL = home.appendingPathComponent(".local/src/codex-speed-lite/.venv/bin/python")
        task.arguments = [home.appendingPathComponent(".local/src/codex-speed-lite/control.py").path, command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            DispatchQueue.main.async { completion(process.terminationStatus == 0) }
        }
        do { try task.run() }
        catch { completion(false) }
    }

    func showReconnectError(_ key: String) {
        let l = Localizer(language: language)
        let alert = NSAlert()
        alert.messageText = l.text("Could not reconnect")
        alert.informativeText = l.text(key)
        alert.runModal()
    }

    @objc func reconnectDesktop() {
        guard !reconnecting else { return }
        let l = Localizer(language: language)
        let alert = NSAlert()
        alert.messageText = l.text("Reconnect desktop monitoring?")
        alert.informativeText = l.text("This enables local monitoring, then fully quits and reopens the Codex desktop app. Active tasks will be interrupted. Restarting only the CLI daemon does not apply desktop settings.")
        alert.addButton(withTitle: l.text("Reconnect"))
        alert.addButton(withTitle: l.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reconnecting = true
        renderSnapshot()
        runControl("enable") { enabled in
            guard enabled else {
                self.reconnecting = false
                self.renderSnapshot()
                self.showReconnectError("Could not enable monitoring. Check that the helper and collector are installed.")
                return
            }
            DesktopClient.restart { error in
                self.reconnecting = false
                self.renderSnapshot()
                if let error { self.showReconnectError(error.messageKey) }
                self.refresh()
            }
        }
    }

    @objc func restoreDirect() {
        let l = Localizer(language: language)
        let alert = NSAlert()
        alert.messageText = l.text("Restore Codex’s direct connection?")
        alert.informativeText = l.text("This removes only the monitor’s configuration. Fully quit and reopen the desktop app afterward. The relay stays running to avoid interrupting current work.")
        alert.addButton(withTitle: l.text("Restore"))
        alert.addButton(withTitle: l.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runControl("disable") { success in
            if success { self.refresh() }
            else { self.rows[10].title = Localizer(language: self.language).text("Restore failed · see About Measurements") }
        }
    }

    func renderSnapshot() {
        let l = Localizer(language: language)
        let now = Date().timeIntervalSince1970
        let view = APIReadout(snapshot: latestSnapshot, legacy: latestLegacy, now: now, localizer: l)
        let compact = CompactReadout(snapshot: latestSnapshot, legacy: latestLegacy, now: now, localizer: l)
        item.button?.title = compact.menuBar
        heading.set(compact.speed)
        subtitle.label.stringValue = reconnecting ? l.text("Reconnecting…") : compact.subtitle
        reconnect.isEnabled = !reconnecting
        delay.set(compact.delay)
        activity.set(compact.activity)
        updated.set(compact.updated)
        let titles = [view.average, view.scope, view.active, view.latest, view.firstOutput,
                      view.age, view.engine, view.quality, l.text("Generation-only speed: not established"),
                      view.diagnostic, l.text(latestRoute), view.service]
        for (row, title) in zip(rows, titles) { row.title = title }
        item.button?.toolTip = l.format("%@. %@. Not pure generation speed.", view.average, view.service)
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let metricsURL = home.appendingPathComponent(".local/share/codex-speed-lite/api-metrics.json")
        let configURL = home.appendingPathComponent(".codex/config.toml")
        worker.async {
            let data = try? Data(contentsOf: metricsURL)
            let snapshot = data.flatMap { try? JSONDecoder().decode(CollectorSnapshot.self, from: $0) }
            let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let legacy = object?["status"] != nil && object?["schema_version"] == nil
            let route = configuredRouting(try? String(contentsOf: configURL, encoding: .utf8))
            DispatchQueue.main.async {
                self.busy = false
                self.latestSnapshot = snapshot
                self.latestLegacy = legacy
                self.latestRoute = route
                self.renderSnapshot()
                if self.showOnLoad {
                    self.showOnLoad = false
                    self.item.button?.performClick(nil)
                }
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    try runSelfTests()
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
