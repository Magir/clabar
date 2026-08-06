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

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService
    @ObservedObject var store: EventStore

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
