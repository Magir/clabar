import SwiftUI

@main
struct ClabarApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("История уведомлений", id: "log") {
            LogWindowView(model: model)
        }
        .defaultSize(width: 820, height: 480)

        // A plain Window instead of the Settings scene: LSUIElement apps have no
        // menu bar entry anyway, and Settings silently no-ops when the app is
        // inactive (popover click) — a Window opened via presentFront is reliable.
        Window("Настройки Clabar", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// Open a window from the menu bar popover and bring it to front: open first
/// (while the popover still holds activation), then activate the app so the
/// new window lands on top instead of behind other apps.
@MainActor
func presentFront(_ open: () -> Void) {
    open()
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
            if !textPart.isEmpty {
                Text(textPart)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .task { await debugAutoOpen() }
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

    private var textPart: String {
        var parts: [String] = []
        if let response = usage.usage {
            var pcts: [String] = []
            if pct5h { pcts.append("\(Int(round(response.pct("five_hour") * 100)))") }
            if pct7d { pcts.append("\(Int(round(response.pct("seven_day") * 100)))") }
            if pctFable, let fable = response.modelBucket("fable") {
                pcts.append("\(Int(round(fable.pct * 100)))")
            }
            if !pcts.isEmpty { parts.append(pcts.joined(separator: "·") + "%") }
        }
        if showUnread {
            let unread = store.unreadCount
            if unread > 0 { parts.append("✉\(unread)") }
        }
        if !model.nudges.isEmpty { parts.append("🔥") }
        return parts.joined(separator: " ")
    }
}
