import Foundation

// Derived from Blimp-Labs/claude-usage-bar (BSD-2-Clause), extended with
// dynamic bucket decoding so new limit windows (e.g. Fable) appear without
// code changes.

struct UsageBucket: Codable, Equatable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        Self.parseResetDate(from: resetsAt)
    }

    func reconciled(with previous: UsageBucket?, resetInterval: TimeInterval, now: Date) -> UsageBucket {
        guard resetsAtDate == nil else { return self }
        guard let previousDate = previous?.resetsAtDate else { return self }
        let resolvedDate = Self.nextResetDate(from: previousDate, resetInterval: resetInterval, now: now)
        return UsageBucket(utilization: utilization, resetsAt: Self.resetString(from: resolvedDate))
    }

    private static func parseResetDate(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        for options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }

        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }

        return nil
    }

    private static func nextResetDate(from previous: Date, resetInterval: TimeInterval, now: Date) -> Date {
        guard resetInterval > 0, previous <= now else { return previous }
        let elapsed = now.timeIntervalSince(previous)
        let stepCount = floor(elapsed / resetInterval) + 1
        return previous.addingTimeInterval(stepCount * resetInterval)
    }

    private static func resetString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct NamedBucket: Identifiable, Equatable {
    let key: String
    let bucket: UsageBucket

    var id: String { key }

    var label: String {
        switch key {
        case "five_hour": return "5 часов"
        case "seven_day": return "Неделя"
        default:
            let isWeekly = key.hasPrefix("seven_day_")
            let name = isWeekly ? String(key.dropFirst("seven_day_".count)) : key
            let pretty = name.split(separator: "_").map(\.capitalized).joined(separator: " ")
            return isWeekly ? "\(pretty) (неделя)" : pretty
        }
    }

    var shortLabel: String {
        switch key {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        default:
            let name = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : key
            return String(name.prefix(2)).capitalized
        }
    }

    var resetInterval: TimeInterval {
        key == "five_hour" ? 5 * 3600 : 7 * 86400
    }

    var pct: Double { (bucket.utilization ?? 0) / 100.0 }
}

struct UsageResponse: Equatable {
    var buckets: [NamedBucket]
    var extraUsage: ExtraUsage?

    func bucket(_ key: String) -> NamedBucket? {
        buckets.first { $0.key == key }
    }

    /// First bucket whose key mentions the given model name (e.g. "fable", "opus").
    func modelBucket(_ name: String) -> NamedBucket? {
        buckets.first { $0.key.contains(name) }
    }

    func pct(_ key: String) -> Double { bucket(key)?.pct ?? 0 }

    func reconciled(with previous: UsageResponse?, now: Date = Date()) -> UsageResponse {
        UsageResponse(
            buckets: buckets.map { named in
                NamedBucket(
                    key: named.key,
                    bucket: named.bucket.reconciled(
                        with: previous?.bucket(named.key)?.bucket,
                        resetInterval: named.resetInterval,
                        now: now
                    )
                )
            },
            extraUsage: extraUsage
        )
    }

    static func decode(from data: Data) throws -> UsageResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Usage response is not an object"))
        }

        let decoder = JSONDecoder()
        var buckets: [NamedBucket] = []
        for (key, value) in json {
            guard key != "extra_usage",
                  let object = value as? [String: Any],
                  object["utilization"] != nil || object["resets_at"] != nil,
                  let objectData = try? JSONSerialization.data(withJSONObject: object),
                  let bucket = try? decoder.decode(UsageBucket.self, from: objectData) else {
                continue
            }
            buckets.append(NamedBucket(key: key, bucket: bucket))
        }
        buckets.sort { Self.order($0.key) < Self.order($1.key) }

        var extra: ExtraUsage?
        if let extraObject = json["extra_usage"] as? [String: Any],
           let extraData = try? JSONSerialization.data(withJSONObject: extraObject) {
            extra = try? decoder.decode(ExtraUsage.self, from: extraData)
        }

        return UsageResponse(buckets: buckets, extraUsage: extra)
    }

    private static func order(_ key: String) -> String {
        switch key {
        case "five_hour": return "0"
        case "seven_day": return "1"
        default: return "2\(key)"
        }
    }
}

struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let utilization: Double?
    let usedCredits: Double?
    let monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }

    /// API returns credits in minor units (cents); convert to dollars.
    var usedCreditsAmount: Double? { usedCredits.map { $0 / 100.0 } }
    var monthlyLimitAmount: Double? { monthlyLimit.map { $0 / 100.0 } }

    static func formatUSD(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}
