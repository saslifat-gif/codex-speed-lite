import AppKit

// The desktop app can be named ChatGPT.app; identify it by bundle ID, not filename.
enum DesktopClient {
    static let bundleIdentifier = "com.openai.codex"

    enum RestartError: Error {
        case multipleApps, notInstalled, quitRefused, timedOut, launchFailed
        var messageKey: String {
            switch self {
            case .multipleApps: return "More than one Codex desktop app is running. Close extra copies and retry."
            case .notInstalled: return "Codex desktop app was not found."
            case .quitRefused, .timedOut: return "Codex did not quit. Close it manually when your work is safe. No force-quit was performed."
            case .launchFailed: return "Codex could not be reopened. Start the desktop app manually."
            }
        }
    }

    static func restart(completion: @escaping (RestartError?) -> Void) {
        precondition(Thread.isMainThread)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard apps.count <= 1 else { completion(.multipleApps); return }
        let app = apps.first
        guard let url = app?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            completion(.notInstalled)
            return
        }
        func launch() {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                DispatchQueue.main.async { completion(error == nil ? nil : .launchFailed) }
            }
        }
        guard let app else { launch(); return }
        guard app.terminate() else { completion(.quitRefused); return }
        func waitForExit(_ remaining: Int) {
            if app.isTerminated { launch() }
            else if remaining == 0 { completion(.timedOut) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForExit(remaining - 1) } }
        }
        waitForExit(120)
    }
}
