import XCTest
@testable import Clabar

final class UsageModelTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("ru", forKey: Lang.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Lang.defaultsKey)
    }

    func testLimitsArrayDecoding() throws {
        let json = """
        {
          "five_hour": {"utilization": 24.0, "resets_at": "2026-08-06T10:29:59.644959+00:00"},
          "seven_day": {"utilization": 58.0, "resets_at": "2026-08-07T01:59:59.644986+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 24, "severity": "normal",
             "resets_at": "2026-08-06T10:29:59.644959+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 58,
             "resets_at": "2026-08-07T01:59:59.644986+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 62,
             "resets_at": "2026-08-07T01:59:59.645285+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
          ],
          "spend": {"percent": 0}
        }
        """
        let response = try UsageResponse.decode(from: Data(json.utf8))

        XCTAssertEqual(response.buckets.map(\.key), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(response.pct("five_hour"), 0.24, accuracy: 0.001)
        XCTAssertEqual(response.pct("seven_day"), 0.58, accuracy: 0.001)

        let fable = try XCTUnwrap(response.modelBucket("fable"))
        XCTAssertEqual(fable.pct, 0.62, accuracy: 0.001)
        XCTAssertEqual(fable.label, "Fable (неделя)")
        XCTAssertEqual(fable.shortLabel, "Fa")
        XCTAssertNotNil(fable.bucket.resetsAtDate)
    }

    func testDynamicBucketDecodingIncludesFable() throws {
        let json = """
        {
          "five_hour": {"utilization": 37.5, "resets_at": "2026-08-06T12:00:00Z"},
          "seven_day": {"utilization": 82, "resets_at": "2026-08-07T03:00:00Z"},
          "seven_day_opus": {"utilization": 10, "resets_at": null},
          "seven_day_fable": {"utilization": 55.2, "resets_at": "2026-08-07T03:00:00Z"},
          "extra_usage": {"is_enabled": true, "utilization": 12, "used_credits": 150, "monthly_limit": 1000},
          "some_scalar": 5
        }
        """
        let response = try UsageResponse.decode(from: Data(json.utf8))

        XCTAssertEqual(response.buckets.map(\.key).prefix(2), ["five_hour", "seven_day"])
        XCTAssertEqual(response.buckets.count, 4)
        XCTAssertEqual(response.pct("five_hour"), 0.375, accuracy: 0.001)

        let fable = try XCTUnwrap(response.modelBucket("fable"))
        XCTAssertEqual(fable.label, "Fable (неделя)")
        XCTAssertEqual(fable.pct, 0.552, accuracy: 0.001)
        XCTAssertNotNil(fable.bucket.resetsAtDate)

        let extra = try XCTUnwrap(response.extraUsage)
        XCTAssertEqual(extra.usedCreditsAmount, 1.5)
    }

    func testFableLabelFormatting() {
        let named = NamedBucket(key: "seven_day_fable", bucket: UsageBucket(utilization: 1, resetsAt: nil))
        XCTAssertEqual(named.label, "Fable (неделя)")
        XCTAssertEqual(named.shortLabel, "Fa")
    }
}

final class NudgeTests: XCTestCase {
    private func usage(_ buckets: [(String, Double, Date?)]) -> UsageResponse {
        let formatter = ISO8601DateFormatter()
        return UsageResponse(buckets: buckets.map { key, utilization, reset in
            NamedBucket(key: key, bucket: UsageBucket(
                utilization: utilization,
                resetsAt: reset.map { formatter.string(from: $0) }
            ))
        }, extraUsage: nil)
    }

    func testNudgeFiresOnLowUsageCloseToReset() {
        let now = Date()
        let response = usage([
            ("five_hour", 10, now.addingTimeInterval(3600)),        // ignored: 5h window
            ("seven_day", 30, now.addingTimeInterval(10 * 3600)),   // fires
            ("seven_day_fable", 90, now.addingTimeInterval(10 * 3600)), // too used
            ("seven_day_opus", 30, now.addingTimeInterval(48 * 3600)),  // too far
        ])
        let nudges = computeNudges(usage: response, thresholdPct: 50, windowHours: 24, now: now)
        XCTAssertEqual(nudges.map(\.bucketKey), ["seven_day"])
        XCTAssertEqual(nudges[0].leftPct, 0.7, accuracy: 0.001)
    }

    func testNoNudgeAfterReset() {
        let now = Date()
        let response = usage([("seven_day", 10, now.addingTimeInterval(-60))])
        XCTAssertTrue(computeNudges(usage: response, thresholdPct: 50, windowHours: 24, now: now).isEmpty)
    }
}

final class HookInstallerTests: XCTestCase {
    func testMergeIntoEmptySettings() {
        let (merged, changed) = HookInstaller.mergedSettings([:])
        XCTAssertTrue(changed)
        let hooks = merged["hooks"] as? [String: Any]
        XCTAssertEqual(Set(hooks?.keys ?? [:].keys), Set(HookInstaller.subscriptions.map(\.event)))

        let preToolUse = hooks?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(preToolUse?.first?["matcher"] as? String, "AskUserQuestion|ExitPlanMode")
    }

    func testMergeIsIdempotentAndPreservesForeignHooks() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [
                    ["matcher": "", "hooks": [["type": "command", "command": "terminal-notifier -message hi"]]]
                ]
            ],
        ]
        let (merged, changed) = HookInstaller.mergedSettings(existing)
        XCTAssertTrue(changed)
        XCTAssertEqual(merged["model"] as? String, "opus")

        let stopGroups = (merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stopGroups?.count, 2) // foreign hook kept, ours appended

        let (again, changedAgain) = HookInstaller.mergedSettings(merged)
        XCTAssertFalse(changedAgain)
        XCTAssertEqual((again["hooks"] as? [String: Any])?.count, (merged["hooks"] as? [String: Any])?.count)
    }
}

final class DevcontainerPatchTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clabar-devc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".devcontainer"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func writeDevcontainer(_ object: [String: Any]) throws -> URL {
        let file = projectURL.appendingPathComponent(".devcontainer/devcontainer.json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: file)
        return file
    }

    private func readDevcontainer(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testPatchPreservesObjectMounts() throws {
        let file = try writeDevcontainer([
            "image": "ubuntu",
            "mounts": [["source": "/host/a", "target": "/a", "type": "bind"]],
            "containerEnv": ["FOO": "1"],
        ])
        let result = try HookInstaller.patchDevcontainer(file: file, projectURL: projectURL)
        XCTAssertEqual(result, .patched)

        let root = try readDevcontainer(file)
        let mounts = try XCTUnwrap(root["mounts"] as? [Any])
        XCTAssertEqual(mounts.count, 2) // object mount survived, ours appended
        XCTAssertNotNil(mounts.first as? [String: Any])
        let env = try XCTUnwrap(root["containerEnv"] as? [String: Any])
        XCTAssertEqual(env["FOO"] as? String, "1")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"] as? String, "/clabar/claude-config")
        XCTAssertEqual(env["CLABAR_HOST"] as? String, "host.docker.internal")
    }

    func testExistingClaudeConfigDirRespectedAndHooksInstalledThere() throws {
        let file = try writeDevcontainer([
            "image": "ubuntu",
            "workspaceFolder": "/workspaces/proj",
            "containerEnv": ["CLAUDE_CONFIG_DIR": "/workspaces/proj/.claude-cfg"],
        ])
        let result = try HookInstaller.patchDevcontainer(file: file, projectURL: projectURL)

        let expectedHost = projectURL.appendingPathComponent(".claude-cfg").path
        XCTAssertEqual(result, .patchedExistingConfig(hooksInstalledAt: expectedHost))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedHost + "/hooks/clabar-hook.sh"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: expectedHost + "/settings.json"))) as? [String: Any])
        XCTAssertNotNil((settings["hooks"] as? [String: Any])?["Stop"])

        let root = try readDevcontainer(file)
        let env = try XCTUnwrap(root["containerEnv"] as? [String: Any])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"] as? String, "/workspaces/proj/.claude-cfg") // untouched
        XCTAssertEqual(env["CLABAR_HOST"] as? String, "host.docker.internal")
        XCTAssertNil(root["mounts"]) // no useless mount added
    }

    func testConfigDirResolvedViaStringMount() throws {
        let file = try writeDevcontainer([
            "image": "ubuntu",
            "mounts": ["source=${localWorkspaceFolder}/cfg,target=/cfg,type=bind"],
            "containerEnv": ["CLAUDE_CONFIG_DIR": "/cfg"],
        ])
        let result = try HookInstaller.patchDevcontainer(file: file, projectURL: projectURL)
        XCTAssertEqual(result, .patchedExistingConfig(
            hooksInstalledAt: projectURL.appendingPathComponent("cfg").path))
    }

    func testJSONCFallsBackToSnippet() throws {
        let file = projectURL.appendingPathComponent(".devcontainer/devcontainer.json")
        try "// comment\n{\"image\": \"ubuntu\"}".write(to: file, atomically: true, encoding: .utf8)
        let result = try HookInstaller.patchDevcontainer(file: file, projectURL: projectURL)
        XCTAssertEqual(result, .needsManualEdit(snippet: HookInstaller.devcontainerSnippet))
    }
}

final class EventClassifierTests: XCTestCase {
    private let headers = [
        "x-clabar-bundle": "com.microsoft.VSCode",
        "x-clabar-term": "vscode",
        "x-clabar-remote": "",
    ]

    func testPermissionRequestIsAsk() throws {
        let event = try XCTUnwrap(EventClassifier.classify(payload: [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "cwd": "/Users/x/proj",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"],
        ], headers: headers))
        XCTAssertEqual(event.kind, .ask)
        XCTAssertTrue(event.message.contains("Bash"))
        XCTAssertTrue(event.message.contains("rm -rf build"))
        XCTAssertEqual(event.project, "proj")
        XCTAssertEqual(event.sourceName, "VS Code")
    }

    func testAskUserQuestionExtractsQuestion() throws {
        let event = try XCTUnwrap(EventClassifier.classify(payload: [
            "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Какую БД используем?"]]],
        ], headers: [:]))
        XCTAssertEqual(event.kind, .ask)
        XCTAssertEqual(event.message, "Какую БД используем?")
    }

    func testStopUsesLastAssistantMessage() throws {
        let event = try XCTUnwrap(EventClassifier.classify(payload: [
            "hook_event_name": "Stop",
            "last_assistant_message": "Готово, тесты зелёные.",
        ], headers: [:]))
        XCTAssertEqual(event.kind, .done)
        XCTAssertEqual(event.message, "Готово, тесты зелёные.")
    }

    func testFailureAndSessionEnd() {
        let failure = EventClassifier.classify(payload: [
            "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
        ], headers: [:])
        XCTAssertEqual(failure?.kind, .error)

        XCTAssertNil(EventClassifier.classify(payload: [
            "hook_event_name": "SessionEnd", "reason": "clear",
        ], headers: [:]))
        XCTAssertEqual(EventClassifier.classify(payload: [
            "hook_event_name": "SessionEnd", "reason": "other",
        ], headers: [:])?.kind, .error)
    }

    func testRemoteFlagFromHeaders(){
        let event = EventClassifier.classify(payload: ["hook_event_name": "Stop"],
                                             headers: ["x-clabar-remote": "true"])
        XCTAssertEqual(event?.isRemote, true)
        XCTAssertEqual(event?.sourceName, "DevContainer")
    }

    func testUnsubscribedToolIsIgnored() {
        XCTAssertNil(EventClassifier.classify(payload: [
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
        ], headers: [:]))
    }
}

@MainActor
final class EventStoreTests: XCTestCase {
    private func makeStore() -> EventStore {
        EventStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("clabar-tests-\(UUID().uuidString)", isDirectory: true))
    }

    func testDedupeCollapsesPermissionOverlap() {
        let store = makeStore()
        var received = [ClaudeEvent]()
        store.onEvent = { received.append($0) }

        let permission = EventClassifier.classify(payload: [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash",
        ], headers: [:])!
        let notification = EventClassifier.classify(payload: [
            "hook_event_name": "Notification", "session_id": "s1",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        ], headers: [:])!

        store.add(permission)
        store.add(permission) // exact duplicate
        store.add(notification) // same ask moment via Notification hook

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(store.unreadCount, 1)

        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testDistinctEventsBothKept() {
        let store = makeStore()
        store.add(EventClassifier.classify(payload: [
            "hook_event_name": "Stop", "session_id": "s1", "last_assistant_message": "A",
        ], headers: [:])!)
        store.add(EventClassifier.classify(payload: [
            "hook_event_name": "Stop", "session_id": "s2", "last_assistant_message": "B",
        ], headers: [:])!)
        XCTAssertEqual(store.events.count, 2)
    }
}
