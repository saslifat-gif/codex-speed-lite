import AppKit

// Native menu material comes from NSMenu; these views only lay out readable labels.
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
    let rows = (0..<12).map { _ in NSMenuItem(title: "—", action: nil, keyEquivalent: "") }
    let heading = MetricMenuRow("Codex Speed", emphasized: true, height: 29)
    let subtitle = MetricMenuRow("Waiting for monitor", secondary: true, height: 21)
    let delay = MetricMenuRow("Response delay")
    let activity = MetricMenuRow("Activity")
    let updated = MetricMenuRow("Last measured")
    var item: NSStatusItem!
    var timer: Timer?
    var busy = false
    var showOnLoad = CommandLine.arguments.contains("--show")

    func addView(_ view: NSView) {
        let row = NSMenuItem()
        row.view = view
        menu.addItem(row)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        details.delegate = self
        menu.autoenablesItems = false
        details.autoenablesItems = false
        addView(heading)
        addView(subtitle)
        menu.addItem(.separator())
        addView(delay)
        addView(activity)
        addView(updated)
        heading.toolTip = "Recent request throughput: total output tokens divided by total request duration. Includes reasoning and API waiting; excludes local tools. Not pure generation speed."
        subtitle.toolTip = "Completed requests in the last minute, across all observed chats and subagents. Concurrent request durations are summed."
        delay.toolTip = "Time to the last completed request’s first observable text, reasoning-summary, or tool-input output. Hidden reasoning may come earlier."
        updated.toolTip = "Age of the last completed sample, not the snapshot file."
        menu.addItem(.separator())
        let more = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        more.submenu = details
        menu.addItem(more)
        for row in rows {
            row.isEnabled = false
            details.addItem(row)
        }
        details.addItem(.separator())
        let history = NSMenuItem(title: "Open History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        details.addItem(history)
        let method = NSMenuItem(title: "About Measurements…", action: #selector(openMethod), keyEquivalent: "")
        method.target = self
        details.addItem(method)
        details.addItem(.separator())
        let restore = NSMenuItem(title: "Restore Direct Connection…", action: #selector(restoreDirect), keyEquivalent: "")
        restore.target = self
        details.addItem(restore)
        let quit = NSMenuItem(title: "Quit Codex Speed", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "The relay stays running so active Codex connections are not interrupted."
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
        item.button?.title = "— t/s"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.button?.setAccessibilityLabel("Codex Speed. Recent request throughput.")
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc func openMethod() { NSWorkspace.shared.open(home.appendingPathComponent(".local/src/codex-speed-lite/README.md")) }
    @objc func openHistory() {
        let folder = home.appendingPathComponent(".local/share/codex-speed-lite/history-v3")
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { openMethod() }
    }

    @objc func restoreDirect() {
        let alert = NSAlert()
        alert.messageText = "Restore Codex’s direct connection?"
        alert.informativeText = "This removes only the monitor’s configuration. Restart Codex afterward. The relay stays running to avoid interrupting current work."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = Process()
        task.executableURL = home.appendingPathComponent(".local/src/codex-speed-lite/.venv/bin/python")
        task.arguments = [home.appendingPathComponent(".local/src/codex-speed-lite/control.py").path, "disable"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            DispatchQueue.main.async {
                if process.terminationStatus == 0 { self.refresh() }
                else { self.rows[10].title = "Restore failed · see About Measurements" }
            }
        }
        do { try task.run() }
        catch { rows[10].title = "Could not run restore helper" }
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
                let now = Date().timeIntervalSince1970
                let view = APIReadout(snapshot: snapshot, legacy: legacy, now: now)
                let compact = CompactReadout(snapshot: snapshot, legacy: legacy, now: now)
                self.item.button?.title = compact.menuBar
                self.heading.set(compact.speed)
                self.subtitle.label.stringValue = compact.subtitle
                self.delay.set(compact.delay)
                self.activity.set(compact.activity)
                self.updated.set(compact.updated)
                let titles = [view.average, view.scope, view.active, view.latest, view.firstOutput,
                              view.age, view.engine, view.quality, "Generation-only speed: not established",
                              view.diagnostic, route, view.service]
                for (row, title) in zip(self.rows, titles) { row.title = title }
                self.item.button?.toolTip = "\(view.average). \(view.service). Not pure generation speed."
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
