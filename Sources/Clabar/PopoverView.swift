import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService
    @ObservedObject var store: EventStore
    @ObservedObject private var lang = LangObserver.shared
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        self.usage = model.usage
        self.store = model.store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if usage.isAuthenticated {
                nudgeBanners
                usageSection
                Divider()
                UsageChartView(historyService: model.history)
            } else {
                signInSection
            }
            Divider()
            notificationsSection
            if let error = usage.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            }
            if let error = model.serverError {
                Label(error, systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.red).font(.caption)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .environment(\.locale, Lang.locale)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // With CFBundleIconFile set this is our AppIcon; generic app icon
            // under `swift run` where there is no bundle.
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 19, height: 19)
            Text("Clabar").font(.headline)
            Spacer()
            if let email = usage.accountEmail {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Nudge

    @ViewBuilder
    private var nudgeBanners: some View {
        ForEach(model.nudges) { nudge in
            banner(
                emoji: "🔥",
                title: "\(nudge.label): \(L("не потрачено", "unused")) \(Int(round(nudge.leftPct * 100)))% \(L("лимита", "of the limit"))",
                subtitle: "\(L("Сброс", "Resets")) \(Text(nudge.resetsAt, style: .relative)) — \(L("самое время нагрузить Клода!", "time to put Claude to work!"))",
                color: .orange
            )
        }
        ForEach(model.lowWarnings) { warning in
            banner(
                emoji: "⚠️",
                title: "\(warning.label): \(L("осталось", "only")) \(Int(round(warning.leftPct * 100)))% \(L("лимита", "of the limit left"))",
                subtitle: "\(L("Сброс", "Resets")) \(Text(warning.resetsAt, style: .relative)) — \(L("притормози или дождись сброса.", "ease off or wait for the reset."))",
                color: .red
            )
        }
    }

    private func banner(emoji: String, title: String, subtitle: LocalizedStringKey, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(emoji)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Usage

    @ViewBuilder
    private var usageSection: some View {
        if let response = usage.usage {
            ForEach(response.buckets) { named in
                UsageBucketRow(named: named)
            }
            if let extra = response.extraUsage, extra.isEnabled {
                ExtraUsageRow(extra: extra)
            }
            if let updated = usage.lastUpdated {
                Text("\(L("Обновлено", "Updated")) \(updated, style: .relative) \(L("назад", "ago"))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var signInSection: some View {
        if usage.isAwaitingCode {
            CodeEntryView(usage: usage)
        } else {
            Text(L("Войдите, чтобы видеть лимиты.", "Sign in to see your usage limits."))
                .font(.subheadline).foregroundStyle(.secondary)
            Button(L("Войти через Claude", "Sign in with Claude")) { usage.startOAuthFlow() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            Text(L("Вход нужен только для лимитов — уведомления, история и настройки работают и без него.",
                   "Sign-in is only needed for limits — notifications, history and settings work without it."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Уведомления", "Notifications")).font(.subheadline.weight(.semibold))
                if store.unreadCount > 0 {
                    Text("\(store.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                if store.unreadCount > 0 {
                    Button(L("Прочитать все", "Mark all read")) { store.markAllRead() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if store.events.isEmpty {
                Text(L("Пока пусто. События придут из хуков Claude Code.",
                       "Nothing yet. Events will arrive from Claude Code hooks."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.events.prefix(6)) { event in
                    EventRow(event: event, store: store) {
                        model.pendingDetailEvent = event
                        presentFront { openWindow(id: "log") }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L("История…", "History…")) { presentFront { openWindow(id: "log") } }
                .buttonStyle(.borderless).font(.caption)
            Button(L("Настройки…", "Settings…")) { presentFront { openWindow(id: "settings") } }
                .buttonStyle(.borderless).font(.caption)
            Spacer()
            Button(L("Обновить", "Refresh")) { Task { await usage.fetchUsage() } }
                .buttonStyle(.borderless).font(.caption)
            Button(L("Закрыть", "Quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows

struct EventRow: View {
    let event: ClaudeEvent
    let store: EventStore
    /// Invoked on row click — opens the event details in the history window.
    let onDetails: () -> Void
    @ObservedObject private var lang = LangObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                store.markRead(event.id)
                onDetails()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: event.kind.symbol)
                        .foregroundStyle(kindColor)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.message)
                            .font(.caption.weight(event.read ? .regular : .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(event.project) · \(event.sourceName) · \(event.date, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if !event.read {
                        Circle().fill(.blue).frame(width: 6, height: 6).padding(.top, 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if event.kind == .ask && !event.read {
                HStack(spacing: 6) {
                    Button(L("⏎ Разрешить", "⏎ Allow")) {
                        store.markRead(event.id)
                        SessionFocus.answer(event, allow: true)
                    }
                    Button(L("⎋ Отклонить", "⎋ Deny")) {
                        store.markRead(event.id)
                        SessionFocus.answer(event, allow: false)
                    }
                    Button(L("Открыть", "Open")) {
                        store.markRead(event.id)
                        SessionFocus.focus(event)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption2)
                .padding(.leading, 18)
            }
        }
    }

    private var kindColor: Color {
        switch event.kind {
        case .ask: return .blue
        case .done: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }
}

struct UsageBucketRow: View {
    let named: NamedBucket
    @ObservedObject private var lang = LangObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(named.label).font(.subheadline)
                Spacer()
                Text(percentageText).font(.subheadline).monospacedDigit()
            }
            ProgressView(value: named.pct, total: 1.0)
                .tint(colorForPct(named.pct))
            if let resetDate = named.bucket.resetsAtDate {
                Text("\(L("Сброс", "Resets")) \(resetDate, style: .relative)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var percentageText: String {
        guard let pct = named.bucket.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Extra Usage").font(.subheadline)
            if let used = extra.usedCreditsAmount, let limit = extra.monthlyLimitAmount {
                HStack {
                    Text("\(ExtraUsage.formatUSD(used)) / \(ExtraUsage.formatUSD(limit))")
                        .font(.caption).monospacedDigit()
                    Spacer()
                    if let pct = extra.utilization {
                        Text("\(Int(round(pct)))%").font(.caption).monospacedDigit()
                    }
                }
                ProgressView(value: (extra.utilization ?? 0) / 100.0, total: 1.0).tint(.blue)
            }
        }
    }
}

private struct CodeEntryView: View {
    @ObservedObject var usage: UsageService
    @State private var code = ""

    var body: some View {
        Text(L("Вставьте код из браузера:", "Paste the code from your browser:"))
            .font(.subheadline).foregroundStyle(.secondary)
        HStack(spacing: 4) {
            TextField("code#state", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submit() }
            Button {
                if let str = NSPasteboard.general.string(forType: .string) {
                    code = str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
        }
        HStack {
            Button(L("Отмена", "Cancel")) { usage.isAwaitingCode = false }
                .buttonStyle(.borderless)
            Spacer()
            Button(L("Готово", "Submit")) { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
        }
    }

    private func submit() {
        let value = code
        Task { await usage.submitOAuthCode(value) }
    }
}

func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
