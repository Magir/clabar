import Foundation

/// Installs the forwarding hook script and registers it in ~/.claude/settings.json.
/// Also patches devcontainer.json so the same setup travels into containers.
enum HookInstaller {
    static let scriptMarker = "clabar-hook"
    static let defaultPort: UInt16 = 8737

    /// Events we subscribe to; matcher "" = all.
    /// (SessionEnd deliberately absent: its reason "other" fires on normal
    /// quits too, producing false "crashed" notifications.)
    static let subscriptions: [(event: String, matcher: String)] = [
        ("Notification", ""),
        ("Stop", ""),
        ("PermissionRequest", ""),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
        ("PostToolUseFailure", ""),
    ]

    static var scriptURL: URL { scriptURL(in: ClabarPaths.claudeDir) }
    static var settingsURL: URL { settingsURL(in: ClabarPaths.claudeDir) }

    static func scriptURL(in claudeDir: URL) -> URL {
        claudeDir.appendingPathComponent("hooks/clabar-hook.sh")
    }

    static func settingsURL(in claudeDir: URL) -> URL {
        claudeDir.appendingPathComponent("settings.json")
    }

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
    static func install(port: UInt16 = defaultPort, into claudeDir: URL = ClabarPaths.claudeDir) throws -> Bool {
        var changed = try writeScript(port: port, claudeDir: claudeDir)

        let settingsFile = settingsURL(in: claudeDir)
        let root = readSettings(at: settingsFile)
        let (merged, settingsChanged) = mergedSettings(root)
        if settingsChanged {
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                let backup = settingsFile.appendingPathExtension("clabar-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: settingsFile, to: backup)
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsFile, options: .atomic)
            changed = true
        }
        return changed
    }

    private static func writeScript(port: UInt16, claudeDir: URL) throws -> Bool {
        let file = scriptURL(in: claudeDir)
        let content = scriptContent(port: port)
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == content {
            return false
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return true
    }

    private static func readSettings(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
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

        // Drop our stale registrations for events we no longer subscribe to.
        let subscribedEvents = Set(subscriptions.map(\.event))
        for (event, value) in hooks where !subscribedEvents.contains(event) {
            guard var groups = value as? [[String: Any]] else { continue }
            let cleaned = groups.filter { group in
                !((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(scriptMarker) == true
                }
            }
            guard cleaned.count != groups.count else { continue }
            groups = cleaned
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
            changed = true
        }

        root["hooks"] = hooks
        return (root, changed)
    }

    /// Which of our subscriptions are currently registered.
    static func installedEvents() -> Set<String> {
        let root = readSettings(at: settingsURL)
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

    static let devcontainerConfigTarget = "/clabar/claude-config"
    static let devcontainerMount = "source=${localEnv:HOME}/.claude,target=\(devcontainerConfigTarget),type=bind"

    /// Manual snippet for JSONC files we refuse to rewrite.
    static var devcontainerSnippet: String {
        """
        "mounts": [
          "\(devcontainerMount)"
        ],
        "containerEnv": {
          "CLAUDE_CONFIG_DIR": "\(devcontainerConfigTarget)",
          "CLABAR_HOST": "host.docker.internal"
        }
        """
    }

    enum DevcontainerPatchResult: Equatable {
        case patched
        case alreadyPatched
        /// The project already points Claude at its own config dir
        /// (CLAUDE_CONFIG_DIR). We keep it, only add CLABAR_HOST, and install
        /// our hooks into that dir when its host path is resolvable.
        case patchedExistingConfig(hooksInstalledAt: String?)
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

    static func patchDevcontainer(file: URL, projectURL: URL, port: UInt16 = defaultPort) throws -> DevcontainerPatchResult {
        let raw = try String(contentsOf: file, encoding: .utf8)
        // JSONC is common in devcontainer.json; JSONSerialization can't
        // round-trip comments, so bail out to a manual snippet.
        guard !raw.contains("//"), !raw.contains("/*"),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return .needsManualEdit(snippet: devcontainerSnippet)
        }

        var root = json
        var changed = false
        var env = root["containerEnv"] as? [String: Any] ?? [:]
        let remoteEnv = root["remoteEnv"] as? [String: Any] ?? [:]
        let customConfigDir = (env["CLAUDE_CONFIG_DIR"] ?? remoteEnv["CLAUDE_CONFIG_DIR"]) as? String

        if customConfigDir == nil {
            // Mount entries may be strings or objects — preserve them as-is.
            var mounts = root["mounts"] as? [Any] ?? []
            if !mounts.contains(where: { ($0 as? String)?.contains(devcontainerConfigTarget) == true }) {
                mounts.append(devcontainerMount)
                root["mounts"] = mounts
                changed = true
            }
            if env["CLAUDE_CONFIG_DIR"] == nil {
                env["CLAUDE_CONFIG_DIR"] = devcontainerConfigTarget
                changed = true
            }
        }
        if env["CLABAR_HOST"] == nil {
            env["CLABAR_HOST"] = "host.docker.internal"
            changed = true
        }
        root["containerEnv"] = env

        if changed {
            let backup = file.appendingPathExtension("clabar-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: file, to: backup)
            }
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: file, options: .atomic)
        }

        if let customConfigDir {
            var installedAt: String?
            if let hostDir = resolveHostPath(containerPath: customConfigDir, root: root, projectURL: projectURL) {
                try install(port: port, into: hostDir)
                installedAt = hostDir.path
            }
            return .patchedExistingConfig(hooksInstalledAt: installedAt)
        }
        return changed ? .patched : .alreadyPatched
    }

    /// Best-effort mapping of a container path back to the host: workspace
    /// folder conventions plus declared bind mounts (string or object form).
    static func resolveHostPath(containerPath: String, root: [String: Any], projectURL: URL) -> URL? {
        for entry in root["mounts"] as? [Any] ?? [] {
            var source: String?
            var target: String?
            if let text = entry as? String {
                for pair in text.split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    if kv[0] == "source" || kv[0] == "src" { source = kv[1] }
                    if kv[0] == "target" || kv[0] == "dst" { target = kv[1] }
                }
            } else if let object = entry as? [String: Any] {
                source = object["source"] as? String
                target = object["target"] as? String
            }
            guard var source, let target,
                  containerPath == target || containerPath.hasPrefix(target + "/") else { continue }
            source = expandLocalVars(source, projectURL: projectURL)
            guard !source.contains("${") else { continue }
            return URL(fileURLWithPath: source + containerPath.dropFirst(target.count))
        }

        let workspaceFolder = (root["workspaceFolder"] as? String)
            ?? "/workspaces/\(projectURL.lastPathComponent)"
        if containerPath == workspaceFolder || containerPath.hasPrefix(workspaceFolder + "/") {
            return URL(fileURLWithPath: projectURL.path + containerPath.dropFirst(workspaceFolder.count))
        }
        return nil
    }

    private static func expandLocalVars(_ value: String, projectURL: URL) -> String {
        value
            .replacingOccurrences(of: "${localEnv:HOME}", with: FileManager.default.homeDirectoryForCurrentUser.path)
            .replacingOccurrences(of: "${localWorkspaceFolder}", with: projectURL.path)
    }
}
