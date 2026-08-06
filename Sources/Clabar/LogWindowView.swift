import SwiftUI

struct LogWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: EventStore

    @State private var searchText = ""
    @State private var kindFilter: EventKind?
    @State private var unreadOnly = false
    @State private var selection = Set<ClaudeEvent.ID>()
    @State private var sortOrder = [KeyPathComparator(\ClaudeEvent.date, order: .reverse)]

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
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Тип", selection: $kindFilter) {
                Text("Все").tag(EventKind?.none)
                ForEach(EventKind.allCases) { kind in
                    Text("\(kind.emoji) \(kind.title)").tag(EventKind?.some(kind))
                }
            }
            .frame(maxWidth: 160)

            Toggle("Непрочитанные", isOn: $unreadOnly)
                .toggleStyle(.checkbox)

            TextField("Поиск по сообщению, проекту, источнику…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Spacer()

            Text("\(filtered.count) из \(store.events.count)")
                .font(.caption).foregroundStyle(.secondary)

            Button("Прочитать все") { store.markAllRead() }
                .disabled(store.unreadCount == 0)
            Button("Очистить журнал", role: .destructive) { store.clear() }
                .disabled(store.events.isEmpty)
        }
        .padding(10)
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Время", value: \.date) { event in
                Text(event.date, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .foregroundStyle(event.read ? .secondary : .primary)
            }
            .width(min: 130, ideal: 140)

            TableColumn("Тип", value: \.kind.rawValue) { event in
                Label(event.kind.title, systemImage: event.kind.symbol)
                    .foregroundStyle(kindColor(event.kind))
            }
            .width(min: 80, ideal: 90)

            TableColumn("Проект", value: \.project) { event in
                Text(event.project)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Источник", value: \.sourceName) { event in
                Text(event.sourceName)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Сообщение", value: \.message) { event in
                Text(event.message)
                    .lineLimit(2)
                    .fontWeight(event.read ? .regular : .semibold)
                    .help(event.message)
            }
        }
        .contextMenu(forSelectionType: ClaudeEvent.ID.self) { ids in
            Button("Открыть сессию") { focus(ids) }
            Button("Отметить прочитанным") {
                for id in ids { store.markRead(id) }
            }
        } primaryAction: { ids in
            focus(ids)
        }
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
