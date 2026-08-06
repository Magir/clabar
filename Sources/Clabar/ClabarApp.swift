import SwiftUI

@main
struct ClabarApp: App {
    @StateObject private var model = AppModel.shared
    @StateObject private var lang = LangObserver.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window(L("История уведомлений", "Notification History"), id: "log") {
            LogWindowView(model: model)
        }
        .defaultSize(width: 820, height: 480)

        // A plain Window instead of the Settings scene: LSUIElement apps have no
        // menu bar entry anyway, and Settings silently no-ops when the app is
        // inactive (popover click) — a Window opened via presentFront is reliable.
        Window(L("Настройки Clabar", "Clabar Settings"), id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// While a real window (history/settings) is open, the app behaves like a
/// regular one — Dock icon, Cmd-Tab; back to menu-bar-only when all close.
@MainActor
enum DockPolicy {
    private static var visibleCount = 0

    /// Must be called BEFORE the window opens: flipping the activation policy
    /// while a window is being presented makes it vanish.
    static func prepareForWindow() {
        NSApp.setActivationPolicy(.regular)
    }

    static func windowShown() {
        visibleCount += 1
    }

    static func windowHidden() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Open a window from the menu bar popover and bring it to front: open first
/// (while the popover still holds activation), then activate the app so the
/// new window lands on top instead of behind other apps. The popover itself
/// (the key window at click time) is closed — unless the click somehow came
/// from one of our real windows.
@MainActor
func presentFront(_ open: () -> Void) {
    DockPolicy.prepareForWindow()
    let clickSource = NSApp.keyWindow
    open()
    let isRealWindow = ["settings", "log"].contains { id in
        clickSource?.identifier?.rawValue.hasPrefix(id) == true
    }
    if !isRealWindow { clickSource?.close() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService
    @ObservedObject var store: EventStore
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKeys.iconShowBars) private var showBars = true
    @AppStorage(SettingsKeys.iconShowUnread) private var showUnread = true
    @AppStorage(SettingsKeys.iconShowPct("five_hour")) private var pct5h = false
    @AppStorage(SettingsKeys.iconShowPct("seven_day")) private var pct7d = false
    @AppStorage(SettingsKeys.iconShowPct("fable")) private var pctFable = false

    init(model: AppModel) {
        self.model = model
        self.usage = model.usage
        self.store = model.store
    }

    var body: some View {
        HStack(spacing: 3) {
            if showBars {
                Image(nsImage: renderIcon(rows: barRows))
            }
            if let status = statusText {
                status.font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .task { await debugAutoOpen() }
    }

    /// One combined Text: in a MenuBarExtra label, standalone Images after the
    /// first are dropped, but SF Symbols embedded in a Text render fine.
    private var statusText: Text? {
        var parts: [Text] = []
        if !pctPart.isEmpty {
            parts.append(Text(pctPart))
        }
        if showUnread, store.unreadCount > 0 {
            parts.append(Text(Image(systemName: "envelope.fill")) + Text("\(store.unreadCount)"))
        }
        if !model.nudges.isEmpty { parts.append(Text("🔥")) }
        if !model.lowWarnings.isEmpty { parts.append(Text("⚠️")) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" ") + $1 }
    }

    /// CLABAR_DEBUG_OPEN=<window id>: open the window at launch and dump its
    /// state to stdout — lets automated runs verify windows come to front.
    private func debugAutoOpen() async {
        guard let target = ProcessInfo.processInfo.environment["CLABAR_DEBUG_OPEN"] else { return }
        try? await Task.sleep(for: .seconds(1))
        presentFront { openWindow(id: target) }
        try? await Task.sleep(for: .seconds(1))
        var lines = NSApp.windows.map {
            "clabar-debug window='\($0.title)' visible=\($0.isVisible) key=\($0.isKeyWindow)"
        }
        lines.append("clabar-debug appActive=\(NSApp.isActive)")
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private var barRows: [IconRow] {
        guard usage.isAuthenticated, let response = usage.usage else {
            return [IconRow(label: "5h", pct: nil), IconRow(label: "7d", pct: nil)]
        }
        var rows = [
            IconRow(label: "5h", pct: response.pct("five_hour")),
            IconRow(label: "7d", pct: response.pct("seven_day")),
        ]
        if pctFable, let fable = response.modelBucket("fable") {
            rows.append(IconRow(label: fable.shortLabel, pct: fable.pct))
        }
        return rows
    }

    private var pctPart: String {
        guard let response = usage.usage else { return "" }
        var pcts: [String] = []
        if pct5h { pcts.append("\(Int(round(response.pct("five_hour") * 100)))") }
        if pct7d { pcts.append("\(Int(round(response.pct("seven_day") * 100)))") }
        if pctFable, let fable = response.modelBucket("fable") {
            pcts.append("\(Int(round(fable.pct * 100)))")
        }
        return pcts.isEmpty ? "" : pcts.joined(separator: "·") + "%"
    }
}
