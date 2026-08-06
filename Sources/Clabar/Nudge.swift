import Foundation

/// "Лимит скоро сгорит" — a weekly-class bucket still has plenty of headroom
/// while its reset is close: nudge the user to burn it.
struct Nudge: Equatable, Identifiable {
    let bucketKey: String
    let label: String
    /// Unused share of the limit, 0...1.
    let leftPct: Double
    let resetsAt: Date

    var id: String { bucketKey }
}

func computeNudges(
    usage: UsageResponse?,
    thresholdPct: Double,
    windowHours: Double,
    now: Date = Date()
) -> [Nudge] {
    guard let usage else { return [] }
    return usage.buckets.compactMap { named in
        // 5-hour window always resets within a day — nudging on it is noise.
        guard named.key != "five_hour",
              let utilization = named.bucket.utilization,
              let resetsAt = named.bucket.resetsAtDate,
              resetsAt > now,
              resetsAt.timeIntervalSince(now) < windowHours * 3600,
              utilization < thresholdPct
        else { return nil }
        return Nudge(
            bucketKey: named.key,
            label: named.label,
            leftPct: max(0, 1 - utilization / 100.0),
            resetsAt: resetsAt
        )
    }
}
