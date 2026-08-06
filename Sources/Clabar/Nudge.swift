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
        // Only the overall weekly window: the 5-hour one always resets soon,
        // and per-model buckets (Fable etc.) would duplicate the same nudge.
        guard named.key == "seven_day",
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

/// The reverse warning: a window (5-hour, weekly, per-model) is almost used up.
func computeLowWarnings(
    usage: UsageResponse?,
    thresholdPct: Double,
    now: Date = Date()
) -> [Nudge] {
    guard let usage else { return [] }
    return usage.buckets.compactMap { named in
        guard let utilization = named.bucket.utilization,
              utilization >= thresholdPct,
              let resetsAt = named.bucket.resetsAtDate,
              resetsAt > now
        else { return nil }
        return Nudge(
            bucketKey: named.key,
            label: named.label,
            leftPct: max(0, 1 - utilization / 100.0),
            resetsAt: resetsAt
        )
    }
}
