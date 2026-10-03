import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

extension TrendMetric {
    var accent: Color {
        switch group {
        case .body: return .body
        case .nutrition: return self == .proteinG ? .protein : (self == .carbsG ? .carbs : (self == .fatG ? .fat : (self == .fiberG ? .fiber : .fuel)))
        case .recovery: return .recover
        case .activity: return .train
        case .cycle: return .protein
        }
    }

    var prefersBars: Bool { isCumulative }

    func format(_ v: Double?) -> String {
        switch self {
        case .weight, .bodyFatPct, .muscleMassKg, .hrvMs: return Fmt.one(v)
        case .sleepMinutes: return Fmt.duration(minutes: v)
        default: return Fmt.int(v)
        }
    }
}

@MainActor
@Observable
final class TrendsModel {
    var range: TrendRange = .month
    var series: [TrendMetric: TrendSeries] = [:]
    var isLoading = false

    func metrics(cycle: Bool) -> [TrendMetric] { TrendMetric.allCases.filter { cycle || $0 != .cycleDay } }

    func load(_ env: AppEnvironment) async {
        isLoading = series.isEmpty
        defer { isLoading = false }
        let repo = env.repository
        let range = self.range
        let wanted = metrics(cycle: env.profile.cycleTrackingEnabled)
        var result: [TrendMetric: TrendSeries] = [:]
        await withTaskGroup(of: (TrendMetric, TrendSeries?).self) { group in
            for m in wanted {
                group.addTask { (m, try? await repo.trend(m, range: range)) }
            }
            for await (m, s) in group { if let s { result[m] = s } }
        }
        series = result
    }
}

struct TrendsHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TrendsModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PillPicker(TrendRange.allCases, selection: $model.range) { $0.label }
                        .listRowBackground(Color.clear)
                    NavigationLink {
                        CompareView(initialRange: model.range)
                    } label: {
                        Label("Compare two metrics", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                ForEach(TrendMetric.Group.allCases, id: \.self) { group in
                    let metrics = model.metrics(cycle: env.profile.cycleTrackingEnabled).filter { $0.group == group }
                    if !metrics.isEmpty {
                        Section(group.rawValue) {
                            ForEach(metrics) { metric in
                                NavigationLink {
                                    TrendDetailView(metric: metric, range: model.range)
                                } label: {
                                    TrendRow(metric: metric, series: model.series[metric])
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trends")
            .overlay { if model.isLoading { ProgressView() } }
            .task(id: "\(env.dataVersion)-\(model.range.rawValue)") { await model.load(env) }
        }
    }
}

struct TrendRow: View {
    let metric: TrendMetric
    let series: TrendSeries?

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.displayName).font(.subheadline.weight(.medium))
                Text("avg \(metric.format(series?.avg)) \(metric == .sleepMinutes ? "" : metric.unit)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let pts = series?.points, pts.count > 1 {
                Sparkline(values: pts.map(\.value), color: metric.accent).frame(width: 90, height: 30)
            }
            if let delta = series?.delta {
                Text(Fmt.signed(delta, digits: metric == .weight || metric == .bodyFatPct ? 1 : 0))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.displayName)
        .accessibilityValue("Average \(metric.format(series?.avg)) \(metric.unit)\(series?.delta.map { ", change \(Fmt.signed($0, digits: 1))" } ?? "")")
    }
}

struct TrendDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let metric: TrendMetric
    @State var range: TrendRange
    @State private var series: TrendSeries?

    init(metric: TrendMetric, range: TrendRange) {
        self.metric = metric
        self._range = State(initialValue: range)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                PillPicker(TrendRange.allCases, selection: $range) { $0.label }
                Card(metric.displayName, systemImage: "chart.xyaxis.line", accent: metric.accent) {
                    if let s = series, !s.points.isEmpty {
                        chart(s)
                        HStack(spacing: Spacing.l) {
                            StatColumn("Average", value: metric.format(s.avg))
                            StatColumn("Min", value: metric.format(s.min))
                            StatColumn("Max", value: metric.format(s.max))
                            StatColumn("Change", value: s.delta.map { Fmt.signed($0, digits: 1) } ?? "—")
                        }
                        Text("Unit: \(s.unit)\(range == .year ? " · weekly averages" : "")").font(.caption).foregroundStyle(.secondary)
                    } else if series == nil {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        EmptyStateView(systemImage: "chart.line.downtrend.xyaxis", title: "No data", message: "Nothing recorded for this period.")
                    }
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle(metric.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) { series = try? await env.repository.trend(metric, range: range) }
    }

    @ViewBuilder private func chart(_ s: TrendSeries) -> some View {
        let unit: Calendar.Component = range == .year ? .weekOfYear : .day
        let avg = range == .year ? [] : Stats.rollingAverage(s.points, windowDays: 7)
        Chart {
            ForEach(s.points) { p in
                if metric.prefersBars {
                    BarMark(x: .value("Date", p.date.startDate(), unit: unit), y: .value(metric.displayName, p.value))
                        .foregroundStyle(metric.accent.opacity(0.55))
                } else {
                    PointMark(x: .value("Date", p.date.startDate(), unit: unit), y: .value(metric.displayName, p.value))
                        .foregroundStyle(metric.accent.opacity(0.45)).symbolSize(18)
                }
            }
            ForEach(avg) { p in
                LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("7-day average", p.value))
                    .foregroundStyle(metric.accent).interpolationMethod(.catmullRom)
            }
            if let a = s.avg {
                RuleMark(y: .value("Average", a)).foregroundStyle(Color.textTertiary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: metric.prefersBars))
        .frame(height: 240)
        .accessibilityLabel("\(metric.displayName) over \(range.label)")
        .accessibilityValue("Average \(metric.format(s.avg)), minimum \(metric.format(s.min)), maximum \(metric.format(s.max))")
    }
}
