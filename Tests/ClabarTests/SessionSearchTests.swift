import XCTest
@testable import Clabar

final class SessionSearchTests: XCTestCase {
    var root: URL!
    var projectsDir: URL!
    var engine: SearchEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clabar-search-tests-\(UUID().uuidString)")
        projectsDir = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        engine = SearchEngine(
            projectsDir: projectsDir,
            databaseURL: root.appendingPathComponent("index.db")
        )
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    @discardableResult
    private func writeSession(
        slug: String = "-Users-magir-demo",
        id: String = UUID().uuidString,
        lines: [[String: Any]],
        mtime: Date? = nil
    ) throws -> URL {
        let dir = projectsDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        let text = try lines
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    private func writeSessionsIndex(slug: String, originalPath: String, entries: [[String: Any]]) throws {
        let dir = projectsDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["version": 1, "originalPath": originalPath, "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("sessions-index.json"))
    }

    private func userMessage(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["content": text]]
    }

    private func assistantMessage(blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "message": ["content": blocks]]
    }

    // MARK: - Morphology

    func testRussianQueryFindsInflectedForms() throws {
        try writeSession(lines: [
            ["type": "ai-title", "aiTitle": "Анализ контрагентов"],
            userMessage("Нужна быстрая проверка 32 контрагентов по дадате"),
        ])
        try engine.refresh()

        let results = try engine.search("проверку контрагента", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Анализ контрагентов")
    }

    func testSpanishQueryFindsInflectedForms() throws {
        try writeSession(lines: [
            userMessage("Las facturas fueron enviadas ayer por la tarde"),
        ])
        try engine.refresh()

        XCTAssertEqual(try engine.search("factura enviada", limit: 10).count, 1)
    }

    func testAllQueryWordsMustMatch() throws {
        try writeSession(lines: [userMessage("Нужна проверка отчёта")])
        try engine.refresh()

        XCTAssertEqual(try engine.search("проверка контрагента", limit: 10).count, 0)
    }

    // MARK: - Extraction

    func testExtractionTakesLastTitleAndSkipsNoise() throws {
        try writeSession(lines: [
            ["type": "ai-title", "aiTitle": "Старое название"],
            ["type": "ai-title", "aiTitle": "Новое название"],
            userMessage("Полезный текст про дедупликацию <system-reminder>секретный шум</system-reminder>"),
            assistantMessage(blocks: [
                ["type": "text", "text": "Ответ про артефакты"],
                ["type": "tool_result", "content": "служебныйвывод инструмента"],
                ["type": "thinking", "thinking": "скрытыемысли о задаче"],
            ]),
            ["type": "file-history-snapshot", "snapshot": "мусорныйснапшот"],
        ])
        try engine.refresh()

        XCTAssertEqual(try engine.search("дедупликация", limit: 10).first?.title, "Новое название")
        XCTAssertEqual(try engine.search("артефакты", limit: 10).count, 1)
        XCTAssertEqual(try engine.search("секретный", limit: 10).count, 0)
        XCTAssertEqual(try engine.search("служебныйвывод", limit: 10).count, 0)
        XCTAssertEqual(try engine.search("скрытыемысли", limit: 10).count, 0)
        XCTAssertEqual(try engine.search("мусорныйснапшот", limit: 10).count, 0)
    }

    func testTitleFallsBackToFirstPromptAndResumeUsesProjectPath() throws {
        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try writeSession(slug: "-Users-magir-demo", id: id, lines: [
            userMessage("Сравнение отчётов спарка за квартал"),
        ])
        try writeSessionsIndex(slug: "-Users-magir-demo", originalPath: "/Users/magir/demo", entries: [
            ["sessionId": id, "firstPrompt": "Сравнение отчётов спарка за квартал",
             "projectPath": "/Users/magir/demo"],
        ])
        try engine.refresh()

        let result = try XCTUnwrap(try engine.search("сравнение отчётов", limit: 10).first)
        XCTAssertEqual(result.title, "Сравнение отчётов спарка за квартал")
        XCTAssertEqual(result.resumeCommand, "cd /Users/magir/demo && claude --resume \(id)")
    }

    func testProjectPathFallsBackToIndexOriginalPath() throws {
        let id = UUID().uuidString
        try writeSession(slug: "-Users-magir-demo", id: id, lines: [
            userMessage("уникальноеслово"),
        ])
        // Session itself is missing from entries — originalPath still applies.
        try writeSessionsIndex(slug: "-Users-magir-demo", originalPath: "/Users/magir/demo", entries: [])
        try engine.refresh()

        let result = try XCTUnwrap(try engine.search("уникальноеслово", limit: 10).first)
        XCTAssertEqual(result.resumeCommand, "cd /Users/magir/demo && claude --resume \(id)")
    }

    func testUnknownProjectPathShowsSlugAndOmitsCd() throws {
        let id = UUID().uuidString
        try writeSession(slug: "-Users-magir-demo", id: id, lines: [
            userMessage("уникальноеслово"),
        ])
        try engine.refresh()

        let result = try XCTUnwrap(try engine.search("уникальноеслово", limit: 10).first)
        XCTAssertEqual(result.projectLabel, "-Users-magir-demo")
        XCTAssertEqual(result.resumeCommand, "claude --resume \(id)")
    }

    // MARK: - Incremental updates

    func testMtimeChangeReindexesSession() throws {
        let id = UUID().uuidString
        try writeSession(id: id, lines: [userMessage("альфа")],
                         mtime: Date(timeIntervalSinceNow: -100))
        try engine.refresh()
        XCTAssertEqual(try engine.search("альфа", limit: 10).count, 1)

        try writeSession(id: id, lines: [userMessage("бета")],
                         mtime: Date(timeIntervalSinceNow: -50))
        try engine.refresh()
        XCTAssertEqual(try engine.search("альфа", limit: 10).count, 0)
        XCTAssertEqual(try engine.search("бета", limit: 10).count, 1)
    }

    func testDeletedSessionDisappearsFromIndex() throws {
        let url = try writeSession(lines: [userMessage("гамма")])
        try engine.refresh()
        XCTAssertEqual(try engine.search("гамма", limit: 10).count, 1)

        try FileManager.default.removeItem(at: url)
        try engine.refresh()
        XCTAssertEqual(try engine.search("гамма", limit: 10).count, 0)
    }

    // MARK: - Snippets

    func testSnippetsShowOriginalWordFormsWithHighlights() throws {
        try writeSession(lines: [
            userMessage("Вчера мы обсуждали большую проверку контрагентов, и это заняло весь день"),
        ])
        try engine.refresh()

        let result = try XCTUnwrap(try engine.search("проверка контрагента", limit: 10).first)
        let segments = try XCTUnwrap(result.snippets.first)
        // Original inflected forms, not stems, and matches are flagged.
        XCTAssertTrue(segments.contains { $0.isMatch && $0.text == "проверку" })
        XCTAssertTrue(segments.contains { $0.isMatch && $0.text == "контрагентов" })
        let joined = segments.map(\.text).joined()
        XCTAssertTrue(joined.contains("проверку контрагентов,"))
    }

    // MARK: - Robustness

    func testSpecialCharactersInQueryDoNotThrow() throws {
        try writeSession(lines: [userMessage("обычный текст")])
        try engine.refresh()

        XCTAssertNoThrow(try engine.search("\"текст(ов)\" OR *", limit: 10))
        XCTAssertEqual(try engine.search("", limit: 10).count, 0)
        XCTAssertEqual(try engine.search("   ", limit: 10).count, 0)
    }
}
