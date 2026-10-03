#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

// MARK: - Palette
//
// HealthApp's own identity: four domain accents (Fuel = amber, Train = coral, Recover = teal, Body = indigo)
// on quiet system-grouped surfaces. Every color has a light and dark variant tuned for contrast.

public extension Color {
    /// Dynamic color from light/dark hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let fuel = Color(light: 0xD98200, dark: 0xFFB547)
    static let train = Color(light: 0xE04E3A, dark: 0xFF7C68)
    static let recover = Color(light: 0x0A9488, dark: 0x41D9C8)
    static let body = Color(light: 0x4A4ED6, dark: 0x9497FF)

    static let protein = Color(light: 0xB8336F, dark: 0xFF73AB)
    static let carbs = Color(light: 0x2A7FCF, dark: 0x63B4FF)
    static let fat = Color(light: 0x8F7F14, dark: 0xDCCB52)
    static let fiber = Color(light: 0x3C8F4C, dark: 0x6FD382)
    static let water = Color(light: 0x1C8ED8, dark: 0x5BC0FF)

    static let surface = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardRaised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let hairline = Color(uiColor: .separator)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Domain accents, used to tint cards, charts and icons consistently.
public enum Domain: String, CaseIterable, Sendable {
    case fuel, train, recover, body

    public var color: Color {
        switch self {
        case .fuel: return .fuel
        case .train: return .train
        case .recover: return .recover
        case .body: return .body
        }
    }

    public var title: String {
        switch self {
        case .fuel: return "Fuel"
        case .train: return "Train"
        case .recover: return "Recover"
        case .body: return "Body"
        }
    }

    public var symbol: String {
        switch self {
        case .fuel: return "fork.knife"
        case .train: return "figure.run"
        case .recover: return "moon.zzz.fill"
        case .body: return "figure.stand"
        }
    }
}

// MARK: - Typography (SF Pro Rounded for numbers, scales with Dynamic Type)

public extension Font {
    static let metricHero = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let metricLarge = Font.system(.title, design: .rounded, weight: .semibold)
    static let metricMedium = Font.system(.title3, design: .rounded, weight: .semibold)
    static let metricSmall = Font.system(.headline, design: .rounded, weight: .semibold)
    static let cardTitle = Font.system(.subheadline, design: .default, weight: .semibold)
    static let caption2Rounded = Font.system(.caption2, design: .rounded, weight: .medium)
}

public enum Spacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let cardRadius: CGFloat = 20
}

// MARK: - Haptics

public enum Haptics {
    @MainActor public static func capture() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    @MainActor public static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor public static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    @MainActor public static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Number formatting

public enum Fmt {
    public static func int(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(0)))
    }

    public static func one(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(1)))
    }

    public static func kcal(_ v: Double?) -> String { int(v) }

    public static func duration(minutes: Double?) -> String {
        guard let minutes else { return "—" }
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }

    public static func signed(_ v: Double, digits: Int = 0) -> String {
        let s = v.formatted(.number.precision(.fractionLength(digits)))
        return v > 0 ? "+\(s)" : s
    }
}
#endif
