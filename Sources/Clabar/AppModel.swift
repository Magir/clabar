import Foundation
import Combine
import AppKit

enum SettingsKeys {
    static let iconShowBars = "iconShowBars"
    static func iconShowPct(_ bucketKey: String) -> String { "iconShowPct.\(bucketKey)" }
    static let iconShowUnread = "iconShowUnread"
    static let nudgeEnabled = "nudgeEnabled"
    static let nudgeThresholdPct = "nudgeThresholdPct" // Int 0-100
    static let nudgeWindowHours = "nudgeWindowHours"   // Int
    static let lowWarnEnabled = "lowWarnEnabled"
    static let lowWarnThresholdPct = "lowWarnThresholdPct" // Int 0-100
    static let serverPort = "serverPort"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let hotkeyKey = "hotkeyKey"
    static let hotkeyCmd = "hotkeyCmd"
    static let hotkeyOption = "hotkeyOption"
    static let hotkeyControl = "hotkeyControl"
    static let hotkeyShift = "hotkeyShift"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            iconShowBars: true,
            iconShowUnread: true,
            iconShowPct("seven_day"): false,
            nudgeEnabled: true,
            nudgeThresholdPct: 50,
            nudgeWindowHours: 24,
            lowWarnEnabled: true,
            lowWarnThresholdPct: 85,
            serverPort: Int(HookInstaller.defaultPort),
            hotkeyEnabled: true,
            hotkeyKey: "U",
            hotkeyCmd: true,
        ])
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let usage = UsageService()
    let history = HistoryService()
    let store = EventStore()
    let notifier: Notifier
    let updater = AppUpdater()
    private var server: EventServer?

    @Published var hooksInstalled = false
    @Published var serverError: String?
    /// Event whose details the history window should show once it opens.
    @Published var pendingDetailEvent: ClaudeEvent?
    /// Ticks every few minutes so time-based UI (nudge, "resets in…") stays fresh.
    @Published var now = Date()

    private var started = false
    private var clockTimer: AnyCancellable?

    private init() {
        notifier = Notifier(store: store)
    }

    func start() {
        guard !started else { return }
        started = true

        SettingsKeys.registerDefaults()
        ClabarPaths.ensureDataDir()
        history.loadHistory()
        store.load()
        usage.historyService = history
        store.onEvent = { [weak self] event in self?.notifier.post(for: event) }
        usage.startPolling()
        startServer()
        autoInstallHooks()

        clockTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }

        HotkeyCenter.shared.action = { Task { @MainActor in MenuBarToggle.toggle() } }
        applyHotkey()
    }

    func applyHotkey() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKeys.hotkeyEnabled) else {
            HotkeyCenter.shared.unregister()
            return
        }
        HotkeyCenter.shared.register(
            key: defaults.string(forKey: SettingsKeys.hotkeyKey) ?? "U",
            cmd: defaults.bool(forKey: SettingsKeys.hotkeyCmd),
            option: defaults.bool(forKey: SettingsKeys.hotkeyOption),
            control: defaults.bool(forKey: SettingsKeys.hotkeyControl),
            shift: defaults.bool(forKey: SettingsKeys.hotkeyShift)
        )
    }

    var serverPort: UInt16 {
        UInt16(clamping: UserDefaults.standard.integer(forKey: SettingsKeys.serverPort))
    }

    func startServer() {
        server?.stop()
        let newServer = EventServer { [weak self] payload, headers in
            guard let event = EventClassifier.classify(payload: payload, headers: headers) else { return }
            Task { @MainActor [weak self] in self?.store.add(event) }
        }
        do {
            try newServer.start(port: serverPort)
            server = newServer
            serverError = nil
        } catch {
            serverError = LT("Не удалось открыть порт {port}: ", "Failed to open port {port}: ", ["port": "\(serverPort)"]) + error.localizedDescription
        }
    }

    private func autoInstallHooks() {
        if ProcessInfo.processInfo.environment["CLABAR_NO_AUTOINSTALL"] != nil {
            hooksInstalled = HookInstaller.isFullyInstalled
            return
        }
        installHooks()
    }

    func installHooks() {
        do {
            try HookInstaller.install(port: serverPort)
            hooksInstalled = HookInstaller.isFullyInstalled
        } catch {
            hooksInstalled = false
            serverError = L("Не удалось установить хуки: ", "Failed to install hooks: ") + error.localizedDescription
        }
    }

    func applyPort() {
        startServer()
        if hooksInstalled { installHooks() } // regenerate script with new default port
    }

    var nudges: [Nudge] {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.nudgeEnabled) else { return [] }
        return computeNudges(
            usage: usage.usage,
            thresholdPct: Double(UserDefaults.standard.integer(forKey: SettingsKeys.nudgeThresholdPct)),
            windowHours: Double(UserDefaults.standard.integer(forKey: SettingsKeys.nudgeWindowHours)),
            now: now
        )
    }

    var lowWarnings: [Nudge] {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.lowWarnEnabled) else { return [] }
        return computeLowWarnings(
            usage: usage.usage,
            thresholdPct: Double(UserDefaults.standard.integer(forKey: SettingsKeys.lowWarnThresholdPct)),
            now: now
        )
    }
}
