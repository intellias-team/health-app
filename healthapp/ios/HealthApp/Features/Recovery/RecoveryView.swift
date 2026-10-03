import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

@MainActor
@Observable
final class RecoveryModel {
    var days: [MergedDay] = []
    var error: String?

    func load(_ env: AppEnvironment) async {
        let today = LocalDate.today()
        do {
            days = try await env.repository.dailyMetrics(from: today.adding(days: -29), to: today).sorted { $0.date < $1.date }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    var today: MetricValues? { days.last?.merged }
    func series(_ key: MetricKey) -> [TrendPoint] { days.compactMap { d in d.merged.value(for: key).map { TrendPoint(date: d.date, value: $0) } } }
}

struct RecoveryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = RecoveryModel()

    private struct StageBar: Identifiable { var id: String { "\(date)-\(stage)" }; let date: Date; let stage: String; let minutes: Double }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    scoresRow
                    sleepStagesCard
                    hrvCard
                    restingHrCard
                    vitalsCard
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.surface)
            .navigationTitle("Recovery")
            .task(id: env.dataVersion) { await model.load(env) }
            .refreshable { await model.load(env) }
        }
    }

    private var scoresRow: some View {
        let m = model.today
        return HStack(spacing: Spacing.m) {
            scoreTile("Readiness", m?.readinessScore, symbol: "bolt.heart.fill")
            scoreTile("Sleep", m?.sleepScore, symbol: "bed.double.fill", caption: Fmt.duration(minutes: m?.sleepMinutes))
        }
    }

    private func scoreTile(_ title: String, _ value: Double?, symbol: String, caption: String? = nil) -> some View {
        VStack(spacing: Spacing.s) {
            ZStack {
                RingView(progress: (value ?? 0) / 100, color: .recover, lineWidth: 10)
                Text(Fmt.int(value)).font(.metricLarge).monospacedDigit()
            }
            .frame(width: 96, height: 96)
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Color.recover)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\(Int($0)) out of 100" } ?? "No data")
    }

    private var sleepStagesCard: some View {
        let recent = model.days.suffix(7)
        let bars: [StageBar] = recent.flatMap { d -> [StageBar] in
            guard let s = d.merged.sleepStages else { return [] }
            let date = d.date.startDate()
            return [StageBar(date: date, stage: "Deep", minutes: s.deepMin), StageBar(date: date, stage: "Core", minutes: s.coreMin + s.unspecifiedMin),
                    StageBar(date: date, stage: "REM", minutes: s.remMin), StageBar(date: date, stage: "Awake", minutes: s.awakeMin)]
        }
        return Card("Sleep stages · last 7 nights", systemImage: "moon.zzz.fill", accent: .recover) {
            Chart(bars) { b in
                BarMark(x: .value("Night", b.date, unit: .day), y: .value("Hours", b.minutes / 60))
                    .foregroundStyle(by: .value("Stage", b.stage))
            }
            .chartForegroundStyleScale(["Deep": Color.body, "Core": Color.recover, "REM": Color.carbs, "Awake": Color.fuel.opacity(0.7)])
            .chartYAxisLabel("hours")
            .frame(height: 180)
            .accessibilityLabel("Sleep stages for the last seven nights")
            if let bed = consistencyText { Text(bed).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// Bedtime spread over the last 7 nights (sleep consistency).
    private var consistencyText: String? {
        let cal = Calendar.current
        let minutes: [Double] = model.days.suffix(7).compactMap { d in
            guard let b = d.merged.bedtimeStart else { return nil }
            var m = Double(cal.component(.hour, from: b) * 60 + cal.component(.minute, from: b))
            if m < 12 * 60 { m += 24 * 60 } // after-midnight bedtimes
            return m
        }
        guard minutes.count >= 3, let sd = Stats.standardDeviation(minutes) else { return nil }
        return "Bedtime varied by about ±\(Int(sd)) min this week."
    }

    private var hrvCard: some View {
        let pts = model.series(.hrvMs)
        let avg7 = Stats.rollingAverage(pts, windowDays: 7)
        let baseline = Stats.mean(pts.map(\.value))
        let method = model.today?.hrvMethod?.uppercased()
        return Card("Heart rate variability", systemImage: "waveform.path.ecg", accent: .recover) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.int(pts.last?.value)).font(.metricLarge).monospacedDigit()
                Text("ms").foregroundStyle(.secondary)
                Spacer()
                Text("30-day avg \(Fmt.int(baseline)) ms").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(pts) { p in
                    PointMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("HRV", p.value))
                        .foregroundStyle(Color.recover.opacity(0.5)).symbolSize(20)
                }
                ForEach(avg7) { p in
                    LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("7-day avg", p.value))
                        .foregroundStyle(Color.recover).interpolationMethod(.catmullRom)
                }
                if let baseline {
                    RuleMark(y: .value("Baseline", baseline)).foregroundStyle(Color.textSecondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(height: 160)
            .accessibilityLabel("HRV, last 30 days")
            .accessibilityValue("Latest \(Int(pts.last?.value ?? 0)) milliseconds, 30-day average \(Int(baseline ?? 0))")
            if let method {
                Text("Measured as \(method). Oura (RMSSD) and Apple Watch (SDNN) values aren't directly comparable, so trends use one source at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var restingHrCard: some View {
        let pts = model.series(.restingHr)
        return Card("Resting heart rate", systemImage: "heart.fill", accent: .recover) {
            Chart(pts) { p in
                LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("bpm", p.value))
                    .foregroundStyle(Color.train).interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 120)
            .accessibilityLabel("Resting heart rate, last 30 days")
            .accessibilityValue("Latest \(Int(pts.last?.value ?? 0)) beats per minute")
        }
    }

    private var vitalsCard: some View {
        let m = model.today
        let temps = model.series(.tempDeviationC).suffix(14)
        return Card("Vitals", systemImage: "thermometer.medium", accent: .recover) {
            HStack(spacing: Spacing.xl) {
                StatColumn("Temperature", value: m?.tempDeviationC.map { Fmt.signed($0, digits: 2) } ?? "—", unit: "°C")
                StatColumn("Respiratory", value: Fmt.one(m?.respiratoryRate), unit: "br/min")
                StatColumn("SpO₂", value: Fmt.one(m?.spo2Pct), unit: "%")
            }
            Chart(Array(temps)) { p in
                BarMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("°C", p.value))
                    .foregroundStyle(p.value >= 0 ? Color.fuel : Color.carbs)
            }
            .frame(height: 90)
            .accessibilityLabel("Temperature deviation from baseline, last 14 days")
            Text("Temperature is shown relative to your personal baseline.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
