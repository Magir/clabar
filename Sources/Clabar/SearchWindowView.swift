import SwiftUI

/// Full-size session search: same service as the popover, richer output.
struct SearchWindowView: View {
    @ObservedObject var search: SessionSearchService
    @ObservedObject private var lang = LangObserver.shared

    init(model: AppModel) {
        self.search = model.search
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(search: search, autofocus: true)
                    .frame(maxWidth: 420)
                Spacer()
                if search.isActive && !search.results.isEmpty {
                    Text("\(search.results.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 380)
        .navigationTitle(L("Поиск по сессиям", "Session Search"))
        .environment(\.locale, Lang.locale)
        .onAppear { DockPolicy.windowShown() }
        .onDisappear { DockPolicy.windowHidden() }
    }

    @ViewBuilder
    private var content: some View {
        if let progress = search.indexingProgress {
            SearchIndexingView(progress: progress)
                .frame(maxWidth: 300, maxHeight: .infinity)
        } else if !search.isActive {
            Text(L("Введите запрос — ищет по всему тексту сессий Claude Code, с учётом словоформ.",
                   "Type a query — searches the full text of your Claude Code sessions, morphology-aware."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 360, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        } else if search.results.isEmpty && !search.isSearching {
            Text(L("Ничего не найдено.", "Nothing found."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(search.results) { result in
                        SearchResultRow(result: result, snippetLimit: 3, showActions: true)
                        Divider()
                    }
                }
                .padding(10)
            }
        }
    }
}

/// The shared search text field (popover + window).
struct SearchField: View {
    @ObservedObject var search: SessionSearchService
    var autofocus = false
    /// Invoked when Esc is pressed with the field already empty — the popover
    /// closes itself, the search window ignores it.
    var onEmptyEscape: (() -> Void)?
    @FocusState private var focused: Bool
    @ObservedObject private var lang = LangObserver.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("Поиск по сессиям…", "Search sessions…"), text: $search.query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                .onExitCommand {
                    if search.query.isEmpty {
                        onEmptyEscape?()
                    } else {
                        search.query = ""
                    }
                }
                .onAppear {
                    guard autofocus else { return }
                    // The field exists a beat before the panel is ready to
                    // hand out first responder — focus on the next turn.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focused = true
                    }
                }
            if search.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if search.isActive {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SearchIndexingView: View {
    let progress: Double
    @ObservedObject private var lang = LangObserver.shared

    var body: some View {
        VStack(spacing: 6) {
            Text(L("Индексирую сессии…", "Indexing sessions…"))
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: progress)
        }
    }
}

/// One search hit: title, project · date, snippets. Click copies the resume
/// command; context menu offers the rest.
struct SearchResultRow: View {
    let result: SearchResult
    var snippetLimit = 1
    var showActions = false
    @ObservedObject private var lang = LangObserver.shared
    @State private var copied = false

    var body: some View {
        Button(action: copyResume) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(result.projectLabel).lineLimit(1)
                        Text("·")
                        Text(result.modified, format: .dateTime.day().month(.abbreviated).year())
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    ForEach(Array(result.snippets.prefix(snippetLimit).enumerated()),
                            id: \.offset) { _, segments in
                        (Text("…") + snippetText(segments) + Text("…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if copied {
                    Label(L("Скопировано", "Copied"), systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else if showActions {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(result.resumeCommand)
        .contextMenu {
            Button(L("Скопировать resume-команду", "Copy resume command")) { copyResume() }
            Button(L("Скопировать название", "Copy title")) {
                copyToPasteboard(result.title)
            }
            if let path = result.projectPath, SearchActions.vsCodeInstalled {
                Button(L("Открыть проект в VS Code", "Open project in VS Code")) {
                    SearchActions.openInVSCode(path: path, title: result.title)
                }
            }
        }
    }

    private func copyResume() {
        copyToPasteboard(result.resumeCommand)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func snippetText(_ segments: [SearchSnippetSegment]) -> Text {
        segments.reduce(Text("")) { acc, segment in
            acc + (segment.isMatch
                   ? Text(segment.text).fontWeight(.bold).foregroundColor(.primary)
                   : Text(segment.text))
        }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

enum SearchActions {
    static var vsCodeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.microsoft.VSCode") != nil
    }

    /// Open the project folder in VS Code and put the session title in the
    /// clipboard — its picker finds sessions by title.
    static func openInVSCode(path: String, title: String) {
        copyToPasteboard(title)
        guard FileManager.default.fileExists(atPath: path),
              let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.microsoft.VSCode") else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
