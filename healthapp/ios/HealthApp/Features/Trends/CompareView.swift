import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

/// Compare two metrics: dual time series + scatter + Pearson r, always with a "correlation is not causation" caveat.
struct CompareView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preset: ComparePreset = ComparePreset.all[0]
    @State private var range: TrendRange
    @State private var nextDay = true
    @State private var result: CompareResult?
    @State private var error: String?

    init(initialRange: TrendRange = .month) {
        _range = State(initialValue: initialRange == .week ? .month : initialRange)
    }

    private var presets: [ComparePreset] {
        ComparePreset.all.filter { !$0.requiresCycleTracking || env.profile.cycleTrackingEnabled }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Card {
                    Picker("Comparison", selection: $preset) {
                        ForEach(presets) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    PillPicker([TrendRange.month, .quarter, .year], selection: $range) { $0.label }
                    Toggle("Compare with the next day", isOn: $nextDay)
                        .font(.subheadline)
                    Text(nextDay ? "e.g. today's \(preset.x.displayName.lowercased()) vs tomorrow's \(preset.y.displayName.lowercased())"
                                 : "Same-day values")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let r = result {
                    dualSeries(r)
                    scatter(r)
                    statsCard(r)
                } else if let error {
                    InfoBanner(message: error, systemImage: "exclamationmark.triangle", tint: .train)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }

                InfoBanner(title: "Correlation is not causation",
                           message: result?.caveat ?? CorrelationAnalyzer.caveat,
                           systemImage: "exclamationmark.bubble", tint: .fuel)
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(preset.id)-\(range.rawValue)-\(nextDay)") { await load() }
    }

    private func load() async {
        result = nil
        do {
            result = try await env.repository.compare(x: preset.x, y: preset.y, range: range, lagDays: nextDay ? (preset.lagDays == 0 ? 0 : 1) : 0)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func dualSeries(_ r: CompareResult) -> some View {
        Card("Over time", systemImage: "chart.xyaxis.line", accent: .recover) {
            seriesChart(r.pairs.map { ($0.date, $0.x) }, metric: r.x)
            seriesChart(r.pairs.map { ($0.date.adding(days: nextDay ? 1 : 0), $0.y) }, metric: r.y)
        }
    }

    private func seriesChart(_ pts: [(LocalDate, Double)], metric: TrendMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.displayName).font(.caption.weight(.semibold)).foregroundStyle(metric.accent)
            Chart(Array(pts.enumerated()), id: \.offset) { item in
                LineMark(x: .value("Date", item.element.0.startDate(), unit: .day), y: .value(metric.displayName, item.element.1))
                    .foregroundStyle(metric.accent)
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 100)
            .accessibilityLabel("\(metric.displayName) over time")
        }
    }

    private func scatter(_ r: CompareResult) -> some View {
        Card("Each point is one day", systemImage: "circle.grid.cross", accent: .recover) {
            Chart(r.pairs) { p in
                PointMark(x: .value(r.x.displayName, p.x), y: .value(r.y.displayName, p.y))
                    .foregroundStyle(Color.recover.opacity(0.7))
            }
            .chartXAxisLabel(r.x.displayName)
            .chartYAxisLabel(r.y.displayName)
            .chartXScale(domain: .automatic(includesZero: false))
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 220)
            .accessibilityLabel("Scatter plot of \(r.x.displayName) versus \(r.y.displayName)")
            .accessibilityValue("\(r.n) days. \(CorrelationAnalyzer.describe(r: r.pearsonR, n: r.n))")
        }
    }

    private func statsCard(_ r: CompareResult) -> some View {
        Card("Relationship", systemImage: "function", accent: .recover) {
            HStack(spacing: Spacing.xl) {
                StatColumn("Pearson r", value: r.pearsonR.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                StatColumn("Days", value: "\(r.n)")
            }
            Text(CorrelationAnalyzer.describe(r: r.pearsonR, n: r.n)).font(.subheadline.weight(.semibold))
            Text("r ranges from −1 to +1. Values near 0 mean little linear relationship. With fewer than ~30 days, results are easily driven by chance.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
