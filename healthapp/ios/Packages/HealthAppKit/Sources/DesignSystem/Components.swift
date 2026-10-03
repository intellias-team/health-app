#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreModels

// MARK: - Card

/// The base surface of the app: rounded, borderless, generous padding.
public struct Card<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let accent: Color
    private let trailing: AnyView?
    private let content: Content

    public init(_ title: String? = nil, systemImage: String? = nil, accent: Color = .accentColor,
                trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.accent = accent; self.trailing = trailing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let title {
                HStack(spacing: Spacing.s) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
    }
}

public struct SectionHeader: View {
    let title: String
    let subtitle: String?
    public init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.s)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Metric tile

public struct MetricTile: View {
    let title: String
    let value: String
    let unit: String?
    let caption: String?
    let systemImage: String
    let accent: Color
    let sparkline: [Double]

    public init(title: String, value: String, unit: String? = nil, caption: String? = nil, systemImage: String,
                accent: Color, sparkline: [Double] = []) {
        self.title = title; self.value = value; self.unit = unit; self.caption = caption
        self.systemImage = systemImage; self.accent = accent; self.sparkline = sparkline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.metricMedium).monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            if !sparkline.isEmpty {
                Sparkline(values: sparkline, color: accent).frame(height: 24)
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(Spacing.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, unit, caption].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Badges

/// "Estimate" / "Weighed" / "Label" / "Entered" — every logged item shows how its quantity is known.
public struct QuantityBadgeView: View {
    let label: String
    let isExact: Bool
    public init(label: String, isExact: Bool) { self.label = label; self.isExact = isExact }

    public var body: some View {
        Label(label, systemImage: isExact ? "scalemass.fill" : "wand.and.stars")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(isExact ? Color.recover : Color.fuel)
            .background((isExact ? Color.recover : Color.fuel).opacity(0.14), in: Capsule())
            .accessibilityLabel(isExact ? "\(label), exact quantity" : "\(label), approximate quantity")
    }
}

/// AI recognition confidence shown as High / Medium / Low.
public struct ConfidenceBadge: View {
    let confidence: Double
    public init(_ confidence: Double) { self.confidence = confidence }

    var level: (String, Color) {
        switch confidence {
        case 0.8...: return ("High", .recover)
        case 0.6..<0.8: return ("Medium", .fuel)
        default: return ("Low", .train)
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(level.1).frame(width: 6, height: 6)
            Text("\(level.0) confidence").font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.cardRaised, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.0) confidence, \(Int(confidence * 100)) percent")
    }
}

/// "540–700 kcal" for estimates, "612 kcal" when exact.
public struct KcalRangeLabel: View {
    let range: NutrientRange
    let font: Font
    public init(_ range: NutrientRange, font: Font = .metricSmall) { self.range = range; self.font = font }
    public var body: some View {
        Group {
            if range.isExact {
                Text("\(Fmt.kcal(range.kcalLow)) kcal")
            } else {
                Text("\(Fmt.kcal(range.kcalLow))–\(Fmt.kcal(range.kcalHigh)) kcal")
            }
        }
        .font(font).monospacedDigit()
        .accessibilityLabel(range.isExact ? "\(Int(range.kcalLow)) calories"
                            : "between \(Int(range.kcalLow)) and \(Int(range.kcalHigh)) calories, estimated")
    }
}

// MARK: - Empty state & banners

public struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(systemImage: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage; self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Neutral informational banner (used for fueling insights and the coach disclaimer).
public struct InfoBanner: View {
    let title: String?
    let message: String
    let systemImage: String
    let tint: Color

    public init(title: String? = nil, message: String, systemImage: String = "info.circle", tint: Color = .recover) {
        self.title = title; self.message = message; self.systemImage = systemImage; self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.body.weight(.semibold)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(.subheadline.weight(.semibold)) }
                Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m + 2)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Small labelled value used inside cards.
public struct StatColumn: View {
    let label: String
    let value: String
    let unit: String?
    let color: Color?
    public init(_ label: String, value: String, unit: String? = nil, color: Color? = nil) {
        self.label = label; self.value = value; self.unit = unit; self.color = color
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.metricSmall).monospacedDigit().foregroundStyle(color ?? .primary)
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Segmented pill selector used for date ranges (7D/30D/90D/1Y).
public struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    public init(_ options: [Value], selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.options = options; self._selection = selection; self.label = label
    }

    public var body: some View {
        Picker("Range", selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
#endif
