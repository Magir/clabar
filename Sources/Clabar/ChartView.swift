import SwiftUI
import Charts

// Derived from Blimp-Labs/claude-usage-bar (BSD-2-Clause); one series per
// known bucket (incl. Fable).

private let seriesColors: [String: Color] = [
    "five_hour": .blue,
    "seven_day": .orange,
]

func seriesColor(for key: String) -> Color {
    if let fixed = seriesColors[key] { return fixed }
    if key.contains("fable") { return .purple }
    if key.contains("opus") { return .green }
    if key.contains("sonnet") { return .teal }
    return .gray
}

func bucketShortLabel(for key: String) -> String {
    NamedBucket(key: key, bucket: UsageBucket(utilization: nil, resetsAt: nil)).shortLabel
}

struct UsageChartView: View {
    @ObservedObject var historyService: HistoryService
    @ObservedObject private var lang = LangObserver.shared
    @State private var selectedRange: TimeRange = .day1
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let points = historyService.downsampledPoints(for: selectedRange)
            if points.isEmpty {
                Text(L("Пока нет истории.", "No history yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                chart(points: points, keys: historyService.knownKeys)
            }
        }
    }

    @ViewBuilder
    private func chart(points: [UsageDataPoint], keys: [String]) -> some View {
        let selected = selectedDate.flatMap { date in
            points.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
        }

        Chart {
            ForEach(keys, id: \.self) { key in
                ForEach(points.filter { $0.values[key] != nil }) { point in
                    LineMark(
                        x: .value("Время", point.timestamp),
                        y: .value("Использование", (point.values[key] ?? 0) * 100)
                    )
                    .foregroundStyle(by: .value("Окно", bucketShortLabel(for: key)))
                    .interpolationMethod(.catmullRom)
                }
            }
            if let selected {
                RuleMark(x: .value("Выбрано", selected.timestamp))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-selectedRange.interval)...Date.now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").font(.caption2) }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: xAxisFormat).font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale(
            domain: keys.map { bucketShortLabel(for: $0) },
            range: keys.map { seriesColor(for: $0) }
        )
        .chartLegend(.visible)
        .chartXSelection(value: $selectedDate)
        .chartPlotStyle { $0.clipped() }
        .overlay(alignment: .top) {
            if let selected { tooltip(for: selected, keys: keys) }
        }
        .frame(height: 120)
    }

    @ViewBuilder
    private func tooltip(for point: UsageDataPoint, keys: [String]) -> some View {
        HStack(spacing: 6) {
            Text(point.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(keys.filter { point.values[$0] != nil }, id: \.self) { key in
                Text("\(bucketShortLabel(for: key)) \(Int(round((point.values[key] ?? 0) * 100)))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(seriesColor(for: key))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1: return .dateTime.hour().minute()
        case .hour6, .day1: return .dateTime.hour()
        case .day7: return .dateTime.weekday(.abbreviated)
        case .day30: return .dateTime.day().month(.abbreviated)
        }
    }
}
