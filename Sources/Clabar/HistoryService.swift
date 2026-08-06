import Foundation
import Combine
import AppKit

// Derived from Blimp-Labs/claude-usage-bar (BSD-2-Clause); datapoints now hold
// a per-bucket map so any window (incl. Fable) is charted.

struct UsageDataPoint: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    /// bucket key -> utilization 0...1
    let values: [String: Double]

    init(timestamp: Date = Date(), values: [String: Double]) {
        self.id = UUID()
        self.timestamp = timestamp
        self.values = values
    }
}

struct UsageHistory: Codable {
    var dataPoints: [UsageDataPoint] = []
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1, hour6, day1, day7, day30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour1: return L("1ч", "1h")
        case .hour6: return L("6ч", "6h")
        case .day1: return L("1д", "1d")
        case .day7: return L("7д", "7d")
        case .day30: return L("30д", "30d")
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1: return 120
        case .hour6: return 180
        default: return 200
        }
    }
}

@MainActor
final class HistoryService: ObservableObject {
    @Published var history = UsageHistory()

    private var flushTimer: AnyCancellable?
    private var isDirty = false
    private var terminationObserver: Any?

    private static let retentionInterval: TimeInterval = 30 * 86400
    private static let flushInterval: TimeInterval = 300

    private static var historyFileURL: URL {
        ClabarPaths.ensureDataDir()
        return ClabarPaths.dataDir.appendingPathComponent("history.json")
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.flushToDisk() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func loadHistory() {
        let url = Self.historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode(UsageHistory.self, from: Data(contentsOf: url))
            loaded.dataPoints = pruned(loaded.dataPoints)
            history = loaded
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            history = UsageHistory()
        }
    }

    func record(usage: UsageResponse) {
        let values = Dictionary(uniqueKeysWithValues: usage.buckets.map { ($0.key, $0.pct) })
        history.dataPoints.append(UsageDataPoint(values: values))
        isDirty = true
        if flushTimer == nil {
            flushTimer = Timer.publish(every: Self.flushInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.flushToDisk() }
        }
    }

    func flushToDisk() {
        guard isDirty else { return }
        history.dataPoints = pruned(history.dataPoints)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: Self.historyFileURL, options: .atomic)
        isDirty = false
        flushTimer?.cancel()
        flushTimer = nil
    }

    /// Bucket keys present anywhere in history, in display order.
    var knownKeys: [String] {
        var keys = Set<String>()
        for point in history.dataPoints { keys.formUnion(point.values.keys) }
        return keys.sorted { a, b in
            func order(_ k: String) -> String {
                k == "five_hour" ? "0" : k == "seven_day" ? "1" : "2\(k)"
            }
            return order(a) < order(b)
        }
    }

    func downsampledPoints(for range: TimeRange) -> [UsageDataPoint] {
        let allPoints = history.dataPoints
        guard allPoints.count > range.targetPointCount else { return allPoints }

        let rangeStart = Date().addingTimeInterval(-range.interval)
        let bucketCount = range.targetPointCount
        let bucketDuration = range.interval / Double(bucketCount)
        var buckets = [[UsageDataPoint]](repeating: [], count: bucketCount)

        for point in allPoints {
            let offset = point.timestamp.timeIntervalSince(rangeStart)
            let index = min(max(Int(offset / bucketDuration), 0), bucketCount - 1)
            buckets[index].append(point)
        }

        return buckets.compactMap { bucket -> UsageDataPoint? in
            guard !bucket.isEmpty else { return nil }
            var sums = [String: (total: Double, count: Int)]()
            for point in bucket {
                for (key, value) in point.values {
                    let current = sums[key] ?? (0, 0)
                    sums[key] = (current.total + value, current.count + 1)
                }
            }
            let averaged = sums.mapValues { $0.total / Double($0.count) }
            let avgTimestamp = bucket.map { $0.timestamp.timeIntervalSince1970 }.reduce(0, +) / Double(bucket.count)
            return UsageDataPoint(timestamp: Date(timeIntervalSince1970: avgTimestamp), values: averaged)
        }
    }

    private func pruned(_ points: [UsageDataPoint]) -> [UsageDataPoint] {
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        return points.filter { $0.timestamp >= cutoff }
    }
}
