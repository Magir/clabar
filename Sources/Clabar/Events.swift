import Foundation
import Combine

enum EventKind: String, Codable, CaseIterable, Identifiable {
    case ask, done, error, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return L("Запрос", "Ask")
        case .done: return L("Готово", "Done")
        case .error: return L("Сбой", "Failure")
        case .info: return L("Инфо", "Info")
        }
    }

    var emoji: String {
        switch self {
        case .ask: return "❓"
        case .done: return "✅"
        case .error: return "⚠️"
        case .info: return "ℹ️"
        }
    }

    var symbol: String {
        switch self {
        case .ask: return "questionmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct ClaudeEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var kind: EventKind
    var hookEvent: String
    var sessionId: String?
    var cwd: String?
    var message: String
    var toolName: String?
    /// App hosting the session (from hook env __CFBundleIdentifier).
    var sourceBundleId: String?
    var termProgram: String?
    var isRemote: Bool = false
    var read: Bool = false

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var sourceName: String {
        if isRemote { return "DevContainer" }
        switch sourceBundleId ?? "" {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.googlecode.iterm2": return "iTerm"
        case "com.apple.Terminal": return "Terminal"
        case let bundle where !bundle.isEmpty:
            return bundle.split(separator: ".").last.map(String.init) ?? bundle
        default:
            return termProgram ?? "?"
        }
    }

    /// Whether the event asks the user to allow/deny something (permission or plan).
    var isAnswerable: Bool {
        kind == .ask && hookEvent != "Notification" || kind == .ask && message.lowercased().contains("permission")
    }
}

enum EventClassifier {
    /// Build an event from raw hook stdin JSON plus metadata headers set by clabar-hook.sh.
    static func classify(payload: [String: Any], headers: [String: String]) -> ClaudeEvent? {
        let hookEvent = payload["hook_event_name"] as? String ?? "?"
        let toolName = payload["tool_name"] as? String
        // Sessions running with bypassPermissions auto-approve: their permission
        // prompts never actually wait for the user — drop them as noise.
        let bypassing = (payload["permission_mode"] as? String)?
            .lowercased().contains("bypass") == true

        var kind: EventKind
        var message: String

        switch hookEvent {
        case "PermissionRequest":
            guard !bypassing else { return nil }
            kind = .ask
            message = L("Требуется разрешение: ", "Permission needed: ") + (toolName ?? L("инструмент", "tool"))
            if let input = payload["tool_input"] as? [String: Any],
               let command = input["command"] as? String {
                message += " — \(command.prefix(120))"
            }
        case "PreToolUse":
            kind = .ask
            switch toolName {
            case "AskUserQuestion":
                if let input = payload["tool_input"] as? [String: Any],
                   let questions = input["questions"] as? [[String: Any]],
                   let first = questions.first?["question"] as? String {
                    message = first
                } else {
                    message = L("Claude задаёт вопрос", "Claude has a question")
                }
            case "ExitPlanMode":
                message = L("План готов к ревью", "Plan is ready for review")
            default:
                return nil // not subscribed to other tools
            }
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            let text = payload["message"] as? String ?? L("Уведомление Claude", "Claude notification")
            message = text
            switch type {
            case "permission_prompt":
                guard !bypassing else { return nil }
                kind = .ask
            case "idle_prompt", "agent_needs_input", "elicitation_dialog":
                kind = .ask
            case "agent_completed":
                kind = .done
            default:
                // No notification_type (older CC) — guess from the text.
                if text.lowercased().contains("permission") || text.lowercased().contains("waiting") {
                    kind = .ask
                } else {
                    kind = .info
                }
            }
        case "Stop":
            kind = .done
            let last = (payload["last_assistant_message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = last.isEmpty ? L("Задача завершена", "Task finished") : String(last.prefix(300))
        case "PostToolUseFailure":
            kind = .error
            var text = L("Сбой инструмента ", "Tool failed: ") + (toolName ?? "?")
            if let error = payload["error"] as? String, !error.isEmpty {
                text += ": \(error.prefix(150))"
            }
            message = text
        case "SessionEnd":
            // reason "other" fires on plain quits too — no way to tell a crash
            // from a normal exit, so SessionEnd is never surfaced.
            return nil
        default:
            return nil
        }

        return ClaudeEvent(
            kind: kind,
            hookEvent: hookEvent,
            sessionId: payload["session_id"] as? String,
            cwd: payload["cwd"] as? String,
            message: message,
            toolName: toolName,
            sourceBundleId: headers["x-clabar-bundle"].flatMap { $0.isEmpty ? nil : $0 },
            termProgram: headers["x-clabar-term"].flatMap { $0.isEmpty ? nil : $0 },
            isRemote: !(headers["x-clabar-remote"] ?? "").isEmpty
        )
    }
}

@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [ClaudeEvent] = [] // newest first

    static func recordKey(_ kind: EventKind) -> String { "recordFor.\(kind.rawValue)" }

    nonisolated static func recordingEnabled(_ kind: EventKind) -> Bool {
        UserDefaults.standard.object(forKey: "recordFor.\(kind.rawValue)") as? Bool ?? true
    }

    /// Called for every accepted (non-deduped) event — the notifier hooks in here.
    var onEvent: ((ClaudeEvent) -> Void)?

    private static let cap = 2000
    private static let dedupeWindow: TimeInterval = 3

    private let directory: URL

    init(directory: URL = ClabarPaths.dataDir) {
        self.directory = directory
    }

    private var fileURL: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("notifications.json")
    }

    var unreadCount: Int { events.lazy.filter { !$0.read }.count }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? decoder.decode([ClaudeEvent].self, from: data) else { return }
        events = loaded
    }

    func add(_ event: ClaudeEvent) {
        guard Self.recordingEnabled(event.kind) else { return }
        // Dedupe: PermissionRequest and Notification(permission_prompt) describe
        // the same moment; identical bursts within the window collapse.
        let isDuplicate = events.lazy.prefix(20).contains {
            $0.kind == event.kind &&
            $0.sessionId == event.sessionId &&
            $0.message == event.message &&
            abs($0.date.timeIntervalSince(event.date)) < Self.dedupeWindow
        }
        let isPermissionOverlap = event.hookEvent == "Notification" && event.kind == .ask &&
            events.lazy.prefix(5).contains {
                $0.kind == .ask && $0.sessionId == event.sessionId &&
                abs($0.date.timeIntervalSince(event.date)) < Self.dedupeWindow
            }
        guard !isDuplicate, !isPermissionOverlap else { return }

        events.insert(event, at: 0)
        if events.count > Self.cap { events.removeLast(events.count - Self.cap) }
        save()
        onEvent?(event)
    }

    func markRead(_ id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].read = true
        save()
    }

    func markAllRead() {
        for index in events.indices { events[index].read = true }
        save()
    }

    func clear() {
        events = []
        save()
    }

    func event(byId id: UUID) -> ClaudeEvent? {
        events.first { $0.id == id }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
