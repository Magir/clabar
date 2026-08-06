import SwiftUI

struct LogWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: EventStore
    @ObservedObject private var lang = LangObserver.shared

    @State private var searchText = ""
    @State private var kindFilter: EventKind?
    @State private var unreadOnly = false
    @State private var selection = Set<ClaudeEvent.ID>()
    @State private var sortOrder = [KeyPathComparator(\ClaudeEvent.date, order: .reverse)]
    @State private var detailEvent: ClaudeEvent?

    init(model: AppModel) {
        self.model = model
        self.store = model.store
    }

    private var filtered: [ClaudeEvent] {
        var events = store.events
        if let kindFilter {
            events = events.filter { $0.kind == kindFilter }
        }
        if unreadOnly {
            events = events.filter { !$0.read }
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            events = events.filter {
                $0.message.lowercased().contains(needle) ||
                $0.project.lowercased().contains(needle) ||
                $0.sourceName.lowercased().contains(needle)
            }
        }
        return events.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
        }
        .frame(minWidth: 700, minHeight: 300)
        .environment(\.locale, Lang.locale)
        .sheet(item: $detailEvent) { event in
            EventDetailView(event: event) { detailEvent = nil }
        }
        .onAppear { DockPolicy.windowShown() }
        .onDisappear { DockPolicy.windowHidden() }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker(L("Тип", "Type"), selection: $kindFilter) {
                Text(L("Все", "All")).tag(EventKind?.none)
                ForEach(EventKind.allCases) { kind in
                    Text("\(kind.emoji) \(kind.title)").tag(EventKind?.some(kind))
                }
            }
            .frame(maxWidth: 160)

            Toggle(L("Непрочитанные", "Unread"), isOn: $unreadOnly)
                .toggleStyle(.checkbox)

            TextField(L("Поиск по сообщению, проекту, источнику…", "Search message, project, source…"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Spacer()

            Text("\(filtered.count) \(L("из", "of")) \(store.events.count)")
                .font(.caption).foregroundStyle(.secondary)

            Button(L("Прочитать все", "Mark all read")) { store.markAllRead() }
                .disabled(store.unreadCount == 0)
            Button(L("Очистить журнал", "Clear log"), role: .destructive) { store.clear() }
                .disabled(store.events.isEmpty)
        }
        .padding(10)
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Время", "Time"), value: \.date) { event in
                Text(event.date, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .foregroundStyle(event.read ? .secondary : .primary)
            }
            .width(min: 140, ideal: 145)

            TableColumn(L("Тип", "Type"), value: \.kind.rawValue) { event in
                Label(event.kind.title, systemImage: event.kind.symbol)
                    .foregroundStyle(kindColor(event.kind))
            }
            .width(min: 95, ideal: 100)

            TableColumn(L("Проект", "Project"), value: \.project) { event in
                Text(event.project)
            }
            .width(min: 110, ideal: 130)

            TableColumn(L("Источник", "Source"), value: \.sourceName) { event in
                Text(event.sourceName)
            }
            .width(min: 100, ideal: 115)

            TableColumn(L("Сообщение", "Message"), value: \.message) { event in
                Text(event.message)
                    .lineLimit(2)
                    .fontWeight(event.read ? .regular : .semibold)
                    .help(event.message)
            }
        }
        .contextMenu(forSelectionType: ClaudeEvent.ID.self) { ids in
            Button(L("Детали…", "Details…")) { showDetails(ids) }
            Button(L("Открыть сессию", "Open session")) { focus(ids) }
            Button(L("Отметить прочитанным", "Mark as read")) {
                for id in ids { store.markRead(id) }
            }
        } primaryAction: { ids in
            showDetails(ids)
        }
    }

    private func showDetails(_ ids: Set<ClaudeEvent.ID>) {
        guard let id = ids.first, let event = store.event(byId: id) else { return }
        store.markRead(id)
        detailEvent = event
    }

    private func focus(_ ids: Set<ClaudeEvent.ID>) {
        guard let id = ids.first, let event = store.event(byId: id) else { return }
        store.markRead(id)
        SessionFocus.focus(event)
    }

    private func kindColor(_ kind: EventKind) -> Color {
        switch kind {
        case .ask: return .blue
        case .done: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }
}

/// Full, untruncated view of a single event.
struct EventDetailView: View {
    let event: ClaudeEvent
    let onClose: () -> Void
    @ObservedObject private var lang = LangObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: event.kind.symbol).font(.title3)
                Text(event.kind.title).font(.headline)
                Spacer()
                Text(event.date, format: .dateTime.day().month().year().hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(event.message)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                detailRow(L("Проект", "Project"), event.project)
                detailRow(L("Источник", "Source"), event.sourceName)
                detailRow(L("Папка", "Directory"), event.cwd ?? "—")
                detailRow(L("Событие хука", "Hook event"), event.hookEvent)
                detailRow(L("Инструмент", "Tool"), event.toolName ?? "—")
                detailRow(L("Сессия", "Session"), event.sessionId ?? "—")
            }
            .font(.caption)

            HStack {
                Button(L("Открыть сессию", "Open session")) {
                    SessionFocus.focus(event)
                    onClose()
                }
                Spacer()
                Button(L("Закрыть", "Close")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .environment(\.locale, Lang.locale)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
