#if canImport(SwiftUI) && canImport(Charts) && canImport(UIKit)
import SwiftUI
import Charts

// MARK: - Ring

/// Progress ring. Values over 100 % draw a second lap in a deeper tint rather than clipping.
public struct RingView: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    public init(progress: Double, color: Color, lineWidth: CGFloat = 10) {
        self.progress = progress; self.color = color; self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(1, progress - 1))
                    .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
    }
}

/// Labelled ring with value/goal, e.g. protein 96 / 140 g.
public struct MacroRing: View {
    let title: String
    let value: Double
    let goal: Double
    let unit: String
    let color: Color

    public init(title: String, value: Double, goal: Double, unit: String = "g", color: Color) {
        self.title = title; self.value = value; self.goal = goal; self.unit = unit; self.color = color
    }

    public var body: some View {
        VStack(spacing: Spacing.s) {
            ZStack {
                RingView(progress: goal > 0 ? value / goal : 0, color: color, lineWidth: 8)
                VStack(spacing: 0) {
                    Text(Fmt.int(value)).font(.metricSmall).monospacedDigit()
                    Text("/ \(Fmt.int(goal))\(unit)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value)) of \(Int(goal)) \(unit == "g" ? "grams" : unit), \(goal > 0 ? Int(value / goal * 100) : 0) percent")
    }
}

// MARK: - Sparkline

public struct Sparkline: View {
    let values: [Double]
    let color: Color

    public init(values: [Double], color: Color) { self.values = values; self.color = color }

    public var body: some View {
        let points = Array(values.enumerated())
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.15, 0.1)
        Chart(points, id: \.offset) { p in
            AreaMark(x: .value("i", p.offset), yStart: .value("min", lo - pad), yEnd: .value("v", p.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("i", p.offset), y: .value("v", p.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(values.isEmpty ? "No data" : "From \(Fmt.one(values.first)) to \(Fmt.one(values.last))")
    }
}

// MARK: - Stacked energy bar

/// Horizontal bar showing resting + active expenditure with an intake marker.
public struct EnergyBar: View {
    let resting: Double
    let active: Double
    let intake: Double

    public init(resting: Double, active: Double, intake: Double) { self.resting = resting; self.active = active; self.intake = intake }

    public var body: some View {
        GeometryReader { geo in
            let total = max(resting + active, intake, 1)
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cardRaised)
                HStack(spacing: 2) {
                    Rectangle().fill(Color.body.opacity(0.55)).frame(width: max(0, w * resting / total - 1))
                    Rectangle().fill(Color.train).frame(width: max(0, w * active / total - 1))
                }
                .clipShape(Capsule())
                Rectangle()
                    .fill(Color.fuel)
                    .frame(width: 3, height: geo.size.height + 8)
                    .offset(x: min(w - 3, w * intake / total))
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy")
        .accessibilityValue("Resting \(Int(resting)), active \(Int(active)), food intake \(Int(intake)) kilocalories")
    }
}
#endif
