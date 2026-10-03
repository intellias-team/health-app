import SwiftUI
import CoreModels
import AnalyticsKit
import DesignSystem

/// Signature card: food intake vs expenditure (Fuel), today's training load (Train) and readiness / sleep / HRV
/// (Recover) side by side — the three things that only make sense together.
struct FuelTrainRecoverCard: View {
    let balance: DailyBalance

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("Fuel · Train · Recover")
                    .font(.headline)
                Spacer()
                Text(balance.date == .today() ? "Today" : balance.date.iso)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.m) { columns }
                VStack(alignment: .leading, spacing: Spacing.m) { columns }
            }

            Text(balance.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Spacing.cardRadius + 4, style: .continuous)
                .fill(Color.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.cardRadius + 4, style: .continuous)
                        .fill(LinearGradient(colors: [Color.fuel.opacity(0.10), Color.train.opacity(0.06), Color.recover.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
    }

    @ViewBuilder private var columns: some View {
        fuelColumn
        trainColumn
        recoverColumn
    }

    private var fuelColumn: some View {
        let e = balance.fuel.energy
        return Pillar(domain: .fuel, label: balance.fuel.label) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Fmt.kcal(e.intakeKcal)).font(.metricMedium).monospacedDigit()
                Text("in").font(.caption).foregroundStyle(.secondary)
            }
            Text("of \(Fmt.kcal(e.totalExpenditureKcal)) kcal used").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: min(1, e.intakeRatio)).tint(.fuel)
            Text("Protein \(Fmt.int(balance.fuel.proteinG)) / \(Fmt.int(balance.fuel.proteinGoalG)) g")
                .font(.caption).foregroundStyle(.secondary)
            if e.intakeIsEstimate { QuantityBadgeView(label: "Includes estimates", isExact: false) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fuel")
        .accessibilityValue("\(Int(e.intakeKcal)) kilocalories eaten of \(Int(e.totalExpenditureKcal)) used. \(balance.fuel.label). Protein \(Int(balance.fuel.proteinG)) of \(Int(balance.fuel.proteinGoalG)) grams.")
    }

    private var trainColumn: some View {
        let t = balance.train
        return Pillar(domain: .train, label: t.label) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Fmt.int(t.loadToday)).font(.metricMedium).monospacedDigit()
                Text("load").font(.caption).foregroundStyle(.secondary)
            }
            Text(t.workoutCount == 0 ? "No workouts" : "\(t.workoutCount) workout\(t.workoutCount == 1 ? "" : "s") · \(Fmt.duration(minutes: t.workoutMinutes))")
                .font(.caption).foregroundStyle(.secondary)
            Text("7-day vs 28-day: \(t.acuteChronic.status.rawValue.lowercased())")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(Fmt.kcal(t.activeKcal)) active kcal").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Train")
        .accessibilityValue("Training load \(Int(t.loadToday)), \(t.label). \(t.workoutCount) workouts. Weekly load \(t.acuteChronic.status.rawValue).")
    }

    private var recoverColumn: some View {
        let r = balance.recover
        return Pillar(domain: .recover, label: r.label) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Fmt.int(r.readiness)).font(.metricMedium).monospacedDigit()
                Text("readiness").font(.caption).foregroundStyle(.secondary)
            }
            Text("Sleep \(Fmt.duration(minutes: r.sleepMinutes))\(r.sleepScore.map { " · \(Int($0))" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if let hrv = r.hrvMs {
                Text("HRV \(Int(hrv)) ms\(r.hrvBaselineMs.map { " (avg \(Int($0)))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rhr = r.restingHr {
                Text("RHR \(Int(rhr)) bpm").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recover")
        .accessibilityValue("Readiness \(r.readiness.map { String(Int($0)) } ?? "unavailable"). Sleep \(Fmt.duration(minutes: r.sleepMinutes)). HRV \(r.hrvMs.map { "\(Int($0)) milliseconds" } ?? "unavailable"). \(r.label).")
    }
}

private struct Pillar<Content: View>: View {
    let domain: Domain
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(domain.title, systemImage: domain.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(domain.color)
            content
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(domain.color.opacity(0.14), in: Capsule())
                .foregroundStyle(domain.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
