import Foundation
import CSnowball
import SQLite3

/// One highlighted fragment of a search snippet.
struct SearchSnippetSegment: Equatable {
    let text: String
    let isMatch: Bool
}

struct SearchResult: Identifiable {
    let sessionId: String
    let title: String
    /// Real project path from sessions-index.json; nil when unknown.
    let projectPath: String?
    /// ~-shortened project path, or the raw folder slug when the path is unknown.
    let projectLabel: String
    let modified: Date
    let snippets: [[SearchSnippetSegment]]

    var id: String { sessionId }

    var resumeCommand: String {
        guard let projectPath else { return "claude --resume \(sessionId)" }
        return "cd \(Self.shellQuote(projectPath)) && claude --resume \(sessionId)"
    }

    static func shellQuote(_ path: String) -> String {
        if path.range(of: "^[A-Za-z0-9/._~-]+$", options: .regularExpression) != nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Full-text index over Claude Code session transcripts
/// (`~/.claude/projects/*/*.jsonl`) — SQLite FTS5 plus snowball stemming.
///
/// Morphology: every token is stemmed by the languages Clabar ships —
/// Cyrillic tokens by the Russian stemmer, Latin tokens by en/es/pt/fr/de —
/// and ALL resulting variants are indexed; the query goes through the same
/// function, so a match in any one language connects the two word forms.
/// Other scripts (CJK, …) fall through unstemmed → exact match still works.
///
/// NOT thread-safe (stemmer envs + sqlite connection) — confine each
/// instance to one queue.
final class SearchEngine {
    private let projectsDir: URL
    private let databaseURL: URL
    private var db: OpaquePointer?

    private let cyrillicStemmers: [Snowball]
    private let latinStemmers: [Snowball]
    private var stemCache: [String: [String]] = [:]

    init(projectsDir: URL, databaseURL: URL) {
        self.projectsDir = projectsDir
        self.databaseURL = databaseURL
        cyrillicStemmers = [Snowball("ru")].compactMap { $0 }
        latinStemmers = ["en", "es", "pt", "fr", "de"].compactMap { Snowball($0) }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    enum SearchError: Error {
        case sqlite(String)
    }

    // MARK: - Indexing

    /// Incrementally sync the index with the sessions on disk. Creates the
    /// database on first run. `progress(done, total)` reports (re)indexed files.
    func refresh(progress: ((Int, Int) -> Void)? = nil) throws {
        let handle = try openDatabase()
        let fm = FileManager.default

        var indexed: [String: Double] = [:] // file_path → mtime
        try query(handle, "SELECT file_path, mtime FROM fts") { stmt in
            indexed[column(stmt, 0)] = sqlite3_column_double(stmt, 1)
        }

        var onDisk: [(url: URL, mtime: Double, slug: String)] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)) ?? []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let date = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                onDisk.append((file, date.timeIntervalSince1970, dir.lastPathComponent))
            }
        }

        let diskPaths = Set(onDisk.map { $0.url.path })
        let stale = indexed.keys.filter { !diskPaths.contains($0) }
        let changed = onDisk.filter { indexed[$0.url.path] != $0.mtime }
        guard !stale.isEmpty || !changed.isEmpty else { return }

        var metaBySlug: [String: ProjectMeta] = [:]

        try exec(handle, "BEGIN")
        defer { try? exec(handle, "COMMIT") }

        let delete = try prepare(handle, "DELETE FROM fts WHERE file_path = ?")
        defer { sqlite3_finalize(delete) }
        for path in stale {
            bindText(delete, 1, path)
            try step(handle, delete)
            sqlite3_reset(delete)
        }

        let insert = try prepare(handle, """
            INSERT INTO fts (title, body, session_id, title_orig, body_orig,
                             project_path, project_label, file_path, mtime)
            VALUES (?,?,?,?,?,?,?,?,?)
            """)
        defer { sqlite3_finalize(insert) }

        for (done, item) in changed.enumerated() {
            progress?(done, changed.count)
            bindText(delete, 1, item.url.path)
            try step(handle, delete)
            sqlite3_reset(delete)

            guard let session = Self.extract(fileURL: item.url) else { continue }

            if metaBySlug[item.slug] == nil {
                metaBySlug[item.slug] = ProjectMeta(
                    directory: projectsDir.appendingPathComponent(item.slug))
            }
            let meta = metaBySlug[item.slug]!
            let sessionId = item.url.deletingPathExtension().lastPathComponent
            let entry = meta.entries[sessionId]
            let projectPath = entry?.projectPath ?? meta.originalPath

            var title = session.title ?? entry?.firstPrompt ?? String(session.body.prefix(120))
            title = title.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if title.count > 80 { title = String(title.prefix(80)) + "…" }

            bindText(insert, 1, stemmedStream(title))
            bindText(insert, 2, stemmedStream(session.body))
            bindText(insert, 3, sessionId)
            bindText(insert, 4, title)
            bindText(insert, 5, session.body)
            bindText(insert, 6, projectPath)
            bindText(insert, 7, projectPath.map(Self.tildePath) ?? item.slug)
            bindText(insert, 8, item.url.path)
            sqlite3_bind_double(insert, 9, item.mtime)
            try step(handle, insert)
            sqlite3_reset(insert)
        }
        progress?(changed.count, changed.count)
    }

    // MARK: - Search

    func search(_ query: String, limit: Int) throws -> [SearchResult] {
        let groups = tokenize(query).map(variants(of:))
        guard !groups.isEmpty else { return [] }
        let handle = try openDatabase()

        let match = groups
            .map { "(" + $0.map { "\"\($0)\"" }.joined(separator: " OR ") + ")" }
            .joined(separator: " AND ")
        let queryStems = Set(groups.flatMap { $0 })

        var results: [SearchResult] = []
        let stmt = try prepare(handle, """
            SELECT session_id, title_orig, body_orig, project_path, project_label, mtime
            FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 5.0, 1.0) LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, match)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let projectPath: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil : column(stmt, 3)
            results.append(SearchResult(
                sessionId: column(stmt, 0),
                title: column(stmt, 1),
                projectPath: projectPath,
                projectLabel: column(stmt, 4),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                snippets: buildSnippets(text: column(stmt, 2), queryStems: queryStems)
            ))
        }
        return results
    }

    // MARK: - Session extraction

    struct ExtractedSession {
        let title: String?
        let body: String
    }

    private static let noiseRegex = try! NSRegularExpression(
        pattern: "<system-reminder>.*?</system-reminder>"
            + "|<ide_[a-z_]+>.*?</ide_[a-z_]+>"
            + "|<local-command-[a-z]+>.*?</local-command-[a-z]+>",
        options: .dotMatchesLineSeparators)

    /// Parse one session .jsonl: last ai-title + user/assistant text blocks,
    /// with service noise stripped. nil when there is no text to index.
    static func extract(fileURL: URL) -> ExtractedSession? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var title: String?
        var parts: [String] = []
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            switch object["type"] as? String {
            case "ai-title":
                if let t = object["aiTitle"] as? String, !t.isEmpty { title = t }
            case "user", "assistant":
                guard let message = object["message"] as? [String: Any] else { return }
                if let text = message["content"] as? String {
                    parts.append(text)
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "text" {
                        if let text = block["text"] as? String { parts.append(text) }
                    }
                }
            default:
                break
            }
        }
        let joined = parts.joined(separator: "\n")
        let ns = NSMutableString(string: joined)
        noiseRegex.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length),
                                  withTemplate: " ")
        let body = (ns as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return ExtractedSession(title: title, body: body)
    }

    /// Per-project metadata from sessions-index.json (may be missing/partial).
    private struct ProjectMeta {
        struct Entry {
            let projectPath: String?
            let firstPrompt: String?
        }
        var originalPath: String?
        var entries: [String: Entry] = [:]

        init(directory: URL) {
            let url = directory.appendingPathComponent("sessions-index.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            originalPath = object["originalPath"] as? String
            for raw in object["entries"] as? [[String: Any]] ?? [] {
                guard let id = raw["sessionId"] as? String else { continue }
                var prompt = raw["firstPrompt"] as? String
                if let p = prompt, p.count > 60 { prompt = String(p.prefix(60)) + "…" }
                entries[id] = Entry(projectPath: raw["projectPath"] as? String,
                                    firstPrompt: prompt)
            }
        }
    }

    // MARK: - Morphology

    private static let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

    private func tokenize(_ text: String) -> [String] {
        let ns = text as NSString
        return Self.wordRegex
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// All stem variants of a word across the shipped languages, deduped.
    private func variants(of word: String) -> [String] {
        if let cached = stemCache[word] { return cached }
        let stemmers: [Snowball]
        if word.unicodeScalars.contains(where: { (0x400...0x4FF).contains($0.value) }) {
            stemmers = cyrillicStemmers
        } else if word.unicodeScalars.contains(where: {
            CharacterSet.letters.contains($0) }) {
            stemmers = latinStemmers
        } else {
            stemmers = []
        }
        var out: [String] = []
        for stemmer in stemmers {
            let stem = stemmer.stem(word)
            if !stem.isEmpty && !out.contains(stem) { out.append(stem) }
        }
        if out.isEmpty { out = [word] }
        stemCache[word] = out
        return out
    }

    /// Space-joined union of stem variants of every token — the indexed stream.
    private func stemmedStream(_ text: String) -> String {
        tokenize(text).flatMap(variants(of:)).joined(separator: " ")
    }

    // MARK: - Snippets

    /// Windows of original text around stem matches, matched words flagged.
    /// ponytail: tokenizes the whole document per result; stream with early
    /// exit if huge sessions ever make search feel slow.
    private func buildSnippets(
        text: String, queryStems: Set<String>,
        maxWindows: Int = 3, context: Int = 6
    ) -> [[SearchSnippetSegment]] {
        let ns = text as NSString
        let tokens = Self.wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !tokens.isEmpty else { return [] }

        let isMatch: [Bool] = tokens.map { token in
            let word = ns.substring(with: token.range).lowercased()
            return variants(of: word).contains { queryStems.contains($0) }
        }

        var windows: [(start: Int, end: Int)] = []
        for (i, match) in isMatch.enumerated() where match {
            let window = (max(0, i - context), min(tokens.count - 1, i + context))
            if let last = windows.last, window.0 <= last.end {
                windows[windows.count - 1].end = window.1
            } else if windows.count < maxWindows {
                windows.append((window.0, window.1))
            } else {
                break
            }
        }
        if windows.isEmpty {
            // Title-only match: show the beginning of the session.
            windows = [(0, min(tokens.count - 1, 2 * context))]
        }

        return windows.map { window in
            var segments: [SearchSnippetSegment] = []
            var plain = ""
            for i in window.start...window.end {
                if i > window.start {
                    let gap = NSRange(
                        location: tokens[i - 1].range.upperBound,
                        length: tokens[i].range.lowerBound - tokens[i - 1].range.upperBound)
                    plain += ns.substring(with: gap)
                }
                let word = ns.substring(with: tokens[i].range)
                if isMatch[i] {
                    if !plain.isEmpty { segments.append(.init(text: plain, isMatch: false)) }
                    plain = ""
                    segments.append(.init(text: word, isMatch: true))
                } else {
                    plain += word
                }
            }
            if !plain.isEmpty { segments.append(.init(text: plain, isMatch: false)) }
            return segments
        }
    }

    // MARK: - Helpers

    static func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - SQLite plumbing

    private func openDatabase() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw SearchError.sqlite("cannot open \(databaseURL.path)")
        }
        db = handle
        try exec(handle, """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                title, body,
                session_id UNINDEXED, title_orig UNINDEXED, body_orig UNINDEXED,
                project_path UNINDEXED, project_label UNINDEXED,
                file_path UNINDEXED, mtime UNINDEXED
            )
            """)
        return handle
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        return stmt
    }

    private func query(_ handle: OpaquePointer, _ sql: String,
                       row: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func step(_ handle: OpaquePointer, _ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SearchError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }
}

/// UI-facing facade over SearchEngine: debounces queries, keeps the index
/// fresh before each search, publishes results on the main thread.
@MainActor
final class SessionSearchService: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    /// 0…1 while a large (re)index runs — nil for quick incremental updates.
    @Published private(set) var indexingProgress: Double?
    @Published private(set) var lastError: String?

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Touched only on `queue` after init.
    private let engine: SearchEngine
    private let queue = DispatchQueue(label: "app.clabar.session-search", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var generation = 0

    init(
        projectsDir: URL = ClabarPaths.claudeDir.appendingPathComponent("projects", isDirectory: true),
        databaseURL: URL = ClabarPaths.dataDir.appendingPathComponent("search-index.db")
    ) {
        engine = SearchEngine(projectsDir: projectsDir, databaseURL: databaseURL)
    }

    private func schedule() {
        pending?.cancel()
        generation += 1
        let gen = generation
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            indexingProgress = nil
            return
        }
        isSearching = true
        let engine = engine
        let item = DispatchWorkItem { [weak self] in
            do {
                try engine.refresh { done, total in
                    guard total >= 20 else { return } // don't flash on tiny updates
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.indexingProgress = Double(done) / Double(max(total, 1))
                    }
                }
                let found = try engine.search(text, limit: 40)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.results = found
                    self.isSearching = false
                    self.indexingProgress = nil
                    self.lastError = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.isSearching = false
                    self.indexingProgress = nil
                    self.lastError = error.localizedDescription
                }
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}

/// Thin wrapper over one snowball stemmer instance. Not thread-safe.
private final class Snowball {
    private let ptr: OpaquePointer

    init?(_ language: String) {
        guard let ptr = sb_stemmer_new(language, "UTF_8") else { return nil }
        self.ptr = ptr
    }

    deinit { sb_stemmer_delete(ptr) }

    func stem(_ word: String) -> String {
        var bytes = Array(word.utf8)
        guard let out = sb_stemmer_stem(ptr, &bytes, Int32(bytes.count)) else { return word }
        let length = Int(sb_stemmer_length(ptr))
        return String(decoding: UnsafeBufferPointer(start: out, count: length), as: UTF8.self)
    }
}
