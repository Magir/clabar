import AppKit
import ApplicationServices

/// Best-effort jump to the app/window hosting a Claude session.
enum SessionFocus {
    static let keystrokesDefaultsKey = "sendKeystrokes"

    static var keystrokesEnabled: Bool {
        UserDefaults.standard.bool(forKey: keystrokesDefaultsKey)
    }

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility grant dialog (once per app+build).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

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
    /// CGEvent needs only the Accessibility permission (the osascript route
    /// additionally needed Automation consent and failed silently without it).
    /// Experimental, off by default.
    static func answer(_ event: ClaudeEvent, allow: Bool) {
        focus(event)
        guard keystrokesEnabled else { return }
        guard accessibilityTrusted else {
            requestAccessibility()
            return
        }
        let keyCode: CGKeyCode = allow ? 36 : 53 // Return / Escape
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
