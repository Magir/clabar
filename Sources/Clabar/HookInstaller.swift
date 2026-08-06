import Foundation

/// Installs the forwarding hook script and registers it in ~/.claude/settings.json.
/// Also patches devcontainer.json so the same setup travels into containers.
enum HookInstaller {
    static let scriptMarker = "clabar-hook"
    static let defaultPort: UInt16 = 8737

    /// Events we subscribe to; matcher "" = all.
    static let subscriptions: [(event: String, matcher: String)] = [
        ("Notification", ""),
        ("Stop", ""),
        ("PermissionRequest", ""),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
        ("PostToolUseFailure", ""),
        ("SessionEnd", ""),
    ]

    static var hooksDir: URL { ClabarPaths.claudeDir.appendingPathComponent("hooks", isDirectory: true) }
    static var scriptURL: URL { hooksDir.appendingPathComponent("clabar-hook.sh") }
    static var settingsURL: URL { ClabarPaths.claudeDir.appendingPathComponent("settings.json") }

    /// Works both on the host and inside a devcontainer (CLAUDE_CONFIG_DIR).
    static let hookCommand = #"sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/clabar-hook.sh""#

    static func scriptContent(port: UInt16) -> String {
        """
        #!/bin/sh
        # Clabar: forward Claude Code hook events to the menu bar app.
        # Fire-and-forget: never blocks or fails the Claude session.
        h="${CLABAR_HOST:-127.0.0.1}"
        p="${CLABAR_PORT:-\(port)}"
        curl -s -m 3 -X POST "http://$h:$p/event" \\
          -H "Content-Type: application/json" \\
          -H "X-Clabar-Term: ${TERM_PROGRAM:-}" \\
          -H "X-Clabar-Bundle: ${__CFBundleIdentifier:-}" \\
          -H "X-Clabar-Remote: ${REMOTE_CONTAINERS:-}${CODESPACES:-}${CONTAINER:-}" \\
          --data-binary @- >/dev/null 2>&1 &
        exit 0
        """
    }

    // MARK: - Install

    @discardableResult
    static func install(port: UInt16 = defaultPort) throws -> Bool {
        var changed = try writeScript(port: port)

        let root = readSettings()
        let (merged, settingsChanged) = mergedSettings(root)
        if settingsChanged {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let backup = settingsURL.appendingPathExtension("clabar-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: settingsURL, to: backup)
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
            changed = true
        }
        return changed
    }

    private static func writeScript(port: UInt16) throws -> Bool {
        let content = scriptContent(port: port)
        if let existing = try? String(contentsOf: scriptURL, encoding: .utf8), existing == content {
            return false
        }
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return true
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Non-destructive merge: appends our hook group per event unless one
    /// already references clabar-hook; never touches other entries.
    static func mergedSettings(_ root: [String: Any]) -> ([String: Any], Bool) {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for subscription in subscriptions {
            var groups = hooks[subscription.event] as? [[String: Any]] ?? []
            let alreadyInstalled = groups.contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(scriptMarker) == true
                }
            }
            guard !alreadyInstalled else { continue }

            var group: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand, "async": true, "timeout": 5]]
            ]
            if !subscription.matcher.isEmpty {
                group["matcher"] = subscription.matcher
            }
            groups.append(group)
            hooks[subscription.event] = groups
            changed = true
        }

        root["hooks"] = hooks
        return (root, changed)
    }

    /// Which of our subscriptions are currently registered.
    static func installedEvents() -> Set<String> {
        let root = readSettings()
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var result = Set<String>()
        for subscription in subscriptions {
            let groups = hooks[subscription.event] as? [[String: Any]] ?? []
            let installed = groups.contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(scriptMarker) == true
                }
            }
            if installed { result.insert(subscription.event) }
        }
        return result
    }

    static var isFullyInstalled: Bool {
        FileManager.default.fileExists(atPath: scriptURL.path) &&
            installedEvents().count == subscriptions.count
    }

    // MARK: - DevContainer

    static let devcontainerMount = "source=${localEnv:HOME}/.claude,target=/clabar/claude-config,type=bind"
    static let devcontainerEnv: [String: String] = [
        "CLAUDE_CONFIG_DIR": "/clabar/claude-config",
        "CLABAR_HOST": "host.docker.internal",
    ]

    /// Manual snippet for JSONC files we refuse to rewrite.
    static var devcontainerSnippet: String {
        """
        "mounts": [
          "\(devcontainerMount)"
        ],
        "containerEnv": {
          "CLAUDE_CONFIG_DIR": "/clabar/claude-config",
          "CLABAR_HOST": "host.docker.internal"
        }
        """
    }

    enum DevcontainerPatchResult {
        case patched
        case alreadyPatched
        /// File has comments or non-standard JSON — rewriting would destroy it.
        case needsManualEdit(snippet: String)
    }

    static func devcontainerFile(inProject projectURL: URL) -> URL? {
        let candidates = [
            projectURL.appendingPathComponent(".devcontainer/devcontainer.json"),
            projectURL.appendingPathComponent(".devcontainer.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func patchDevcontainer(file: URL) throws -> DevcontainerPatchResult {
        let raw = try String(contentsOf: file, encoding: .utf8)
        // JSONC is common in devcontainer.json; JSONSerialization can't
        // round-trip comments, so bail out to a manual snippet.
        guard !raw.contains("//"), !raw.contains("/*"),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return .needsManualEdit(snippet: devcontainerSnippet)
        }

        var root = json
        var changed = false

        var mounts = root["mounts"] as? [String] ?? []
        if !mounts.contains(where: { $0.contains("/clabar/claude-config") }) {
            mounts.append(devcontainerMount)
            root["mounts"] = mounts
            changed = true
        }

        var env = root["containerEnv"] as? [String: Any] ?? [:]
        for (key, value) in devcontainerEnv where env[key] == nil {
            env[key] = value
            changed = true
        }
        root["containerEnv"] = env

        guard changed else { return .alreadyPatched }

        let backup = file.appendingPathExtension("clabar-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: file, options: .atomic)
        return .patched
    }
}
