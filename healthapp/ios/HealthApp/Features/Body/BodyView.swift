import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

@MainActor
@Observable
final class BodyModel {
    var range: TrendRange = .quarter
    var measurements: [BodyMeasurement] = []
    var error: String?

    func load(_ env: AppEnvironment) async {
        let today = LocalDate.today()
        do {
            measurements = try await env.repository.bodyMeasurements(from: today.adding(days: -(range.days - 1)), to: today)
                .sorted { $0.measuredAt < $1.measuredAt }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Last measurement of each day for a field.
    func daily(_ field: (BodyMeasurement) -> Double?) -> [TrendPoint] {
        var byDay: [LocalDate: Double] = [:]
        for m in measurements { if let v = field(m) { byDay[LocalDate(m.measuredAt)] = v } }
        return byDay.map { TrendPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    var latest: BodyMeasurement? { measurements.last }
    func latestValue(_ field: (BodyMeasurement) -> Double?) -> Double? { measurements.last(where: { field($0) != nil }).flatMap(field) }
}

struct BodyView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = BodyModel()
    @State private var adding = false

    private var imperial: Bool { env.profile.units == .imperial }
    private func w(_ kg: Double) -> Double { imperial ? Units.kgToLb(kg) : kg }
    private var wUnit: String { imperial ? "lb" : "kg" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    PillPicker([TrendRange.month, .quarter, .year], selection: $model.range) { $0.label }
                    weightCard
                    compositionCard
                    sourcesNote
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.surface)
            .navigationTitle("Body")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add measurement")
                }
            }
            .sheet(isPresented: $adding) { NavigationStack { AddMeasurementView() } }
            .task(id: "\(env.dataVersion)-\(model.range.rawValue)") { await model.load(env) }
            .refreshable { await model.load(env) }
        }
    }

    private var weightCard: some View {
        let pts = model.daily(\.weightKg).map { TrendPoint(date: $0.date, value: w($0.value)) }
        let avg = Stats.rollingAverage(pts, windowDays: 7)
        let weekChange: Double? = {
            guard let last = avg.last, let prior = avg.last(where: { $0.date <= last.date.adding(days: -7) }) else { return nil }
            return last.value - prior.value
        }()
        return Card("Weight", systemImage: "scalemass.fill", accent: .body) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.one(pts.last?.value)).font(.metricHero).monospacedDigit()
                Text(wUnit).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("7-day avg \(Fmt.one(avg.last?.value))").font(.subheadline)
                    if let weekChange { Text("\(Fmt.signed(weekChange, digits: 1)) \(wUnit) vs last week").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Chart {
                ForEach(pts) { p in
                    PointMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("Weight", p.value))
                        .foregroundStyle(Color.body.opacity(0.35)).symbolSize(16)
                }
                ForEach(avg) { p in
                    LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("7-day average", p.value))
                        .foregroundStyle(Color.body).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 200)
            .accessibilityLabel("Weight with 7-day average")
            .accessibilityValue("Latest \(Fmt.one(pts.last?.value)) \(wUnit), 7-day average \(Fmt.one(avg.last?.value))")
            Text("Daily weight naturally fluctuates with water and food; the 7-day average shows the trend.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var compositionCard: some View {
        let fat = model.daily(\.bodyFatPct)
        return Card("Body composition", systemImage: "figure.stand", accent: .body) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Spacing.m) {
                StatColumn("Body fat", value: Fmt.one(model.latestValue(\.bodyFatPct)), unit: "%")
                StatColumn("Lean mass", value: model.latestValue(\.leanMassKg).map { Fmt.one(w($0)) } ?? "—", unit: wUnit)
                StatColumn("Muscle mass", value: model.latestValue(\.muscleMassKg).map { Fmt.one(w($0)) } ?? "—", unit: wUnit)
                StatColumn("BMI", value: Fmt.one(model.latestValue(\.bmi)))
                StatColumn("Body water", value: Fmt.int(model.latestValue(\.waterPct)), unit: "%")
                StatColumn("Bone mass", value: model.latestValue(\.boneMassKg).map { Fmt.one(w($0)) } ?? "—", unit: wUnit)
            }
            if !fat.isEmpty {
                Chart(fat) { p in
                    LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("Body fat %", p.value))
                        .foregroundStyle(Color.body).interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 120)
                .accessibilityLabel("Body fat percentage trend")
            }
            Text("Lean mass (from Apple Health) and muscle mass (from smart scales) are different measures and are shown separately. Scale body-composition values are estimates.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourcesNote: some View {
        let sources = Set(model.measurements.map(\.source)).sorted()
        return Text(sources.isEmpty ? "No measurements yet. Add one, or connect a smart scale that syncs to Apple Health."
                                    : "Sources: \(sources.joined(separator: ", "))")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddMeasurementView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var weight: Double?
    @State private var bodyFat: Double?
    @State private var writeToHealth = true
    @State private var error: String?

    private var imperial: Bool { env.profile.units == .imperial }

    var body: some View {
        Form {
            DatePicker("Date", selection: $date, in: ...Date())
            LabeledContent("Weight (\(imperial ? "lb" : "kg"))") {
                TextField("0.0", value: $weight, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Body fat (%)") {
                TextField("optional", value: $bodyFat, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Toggle("Also save to Apple Health", isOn: $writeToHealth)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Add measurement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let kg = weight.map { imperial ? Units.lbToKg($0) : $0 }
                        var m = BodyMeasurement(measuredAt: date, source: "manual", weightKg: kg, bodyFatPct: bodyFat)
                        if let kg, let h = env.profile.heightCm, h > 0 { m.bmi = (kg / pow(h / 100, 2) * 10).rounded() / 10 }
                        do {
                            try await env.addBodyMeasurement(m, writeToHealth: writeToHealth)
                            Haptics.success()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(weight == nil && bodyFat == nil)
            }
        }
    }
}
