import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService
    @ObservedObject var store: EventStore
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
    }

    private var header: some View {
        HStack {
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
            HStack(alignment: .top, spacing: 8) {
                Text("🔥")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(nudge.label): не потрачено \(Int(round(nudge.leftPct * 100)))% лимита")
                        .font(.callout.weight(.semibold))
                    Text("Сброс \(nudge.resetsAt, style: .relative) — самое время нагрузить Клода!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
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
                Text("Обновлено \(updated, style: .relative) назад")
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
            Text("Войдите, чтобы видеть лимиты.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Войти через Claude") { usage.startOAuthFlow() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            Text("Вход нужен только для лимитов — уведомления, история и настройки работают и без него.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Уведомления").font(.subheadline.weight(.semibold))
                if store.unreadCount > 0 {
                    Text("\(store.unreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                if store.unreadCount > 0 {
                    Button("Прочитать все") { store.markAllRead() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if store.events.isEmpty {
                Text("Пока пусто. События придут из хуков Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.events.prefix(6)) { event in
                    EventRow(event: event, store: store)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("История…") { presentFront { openWindow(id: "log") } }
                .buttonStyle(.borderless).font(.caption)
            Button("Настройки…") { presentFront { openWindow(id: "settings") } }
                .buttonStyle(.borderless).font(.caption)
            Spacer()
            Button("Обновить") { Task { await usage.fetchUsage() } }
                .buttonStyle(.borderless).font(.caption)
            Button("Выход") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows

struct EventRow: View {
    let event: ClaudeEvent
    let store: EventStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                store.markRead(event.id)
                SessionFocus.focus(event)
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
                    Button("⏎ Разрешить") {
                        store.markRead(event.id)
                        SessionFocus.answer(event, allow: true)
                    }
                    Button("⎋ Отклонить") {
                        store.markRead(event.id)
                        SessionFocus.answer(event, allow: false)
                    }
                    Button("Открыть") {
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
                Text("Сброс \(resetDate, style: .relative)")
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
        Text("Вставьте код из браузера:")
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
            Button("Отмена") { usage.isAwaitingCode = false }
                .buttonStyle(.borderless)
            Spacer()
            Button("Готово") { submit() }
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
