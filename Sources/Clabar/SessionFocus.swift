import AppKit

/// Best-effort jump to the app/window hosting a Claude session.
enum SessionFocus {
    static let keystrokesDefaultsKey = "sendKeystrokes"

    private static let termProgramBundles: [String: String] = [
        "vscode": "com.microsoft.VSCode",
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
    ]

    static func bundleId(for event: ClaudeEvent) -> String? {
        if let bundle = event.sourceBundleId, !bundle.isEmpty { return bundle }
        if let term = event.termProgram, let mapped = termProgramBundles[term] { return mapped }
        return nil
    }

    static func focus(_ event: ClaudeEvent) {
        guard let bundle = bundleId(for: event) else { return }

        // VS Code with a locally-existing cwd: open the folder — VS Code raises
        // the window that already has it.
        if bundle == "com.microsoft.VSCode",
           !event.isRemote,
           let cwd = event.cwd,
           FileManager.default.fileExists(atPath: cwd),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: cwd, isDirectory: true)],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            running.activate()
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Focus the session and (if enabled in settings) answer the prompt with a
    /// keystroke: Return = accept the highlighted default, Escape = dismiss.
    /// Needs the Accessibility permission; experimental, off by default.
    static func answer(_ event: ClaudeEvent, allow: Bool) {
        focus(event)
        guard UserDefaults.standard.bool(forKey: keystrokesDefaultsKey) else { return }
        let keyCode = allow ? 36 : 53 // Return / Escape
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let script = "tell application \"System Events\" to key code \(keyCode)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }
}
