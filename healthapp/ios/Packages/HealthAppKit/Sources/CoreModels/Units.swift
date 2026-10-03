import Foundation

/// Unit conversion & formatting helpers. Everything is stored metric; conversion happens at the edges.
public enum Units {
    public static let gramsPerOunce = 28.349523125
    public static let gramsPerPound = 453.59237
    public static let kgPerPound = 0.45359237
    public static let cmPerInch = 2.54
    public static let mlPerFluidOunce = 29.5735295625

    public static func kgToLb(_ kg: Double) -> Double { kg / kgPerPound }
    public static func lbToKg(_ lb: Double) -> Double { lb * kgPerPound }
    public static func gramsToOunces(_ g: Double) -> Double { g / gramsPerOunce }
    public static func ouncesToGrams(_ oz: Double) -> Double { oz * gramsPerOunce }
    public static func cmToInches(_ cm: Double) -> Double { cm / cmPerInch }
    public static func mlToFlOz(_ ml: Double) -> Double { ml / mlPerFluidOunce }

    public static func formatWeight(kg: Double, system: UnitSystem, fractionDigits: Int = 1) -> String {
        switch system {
        case .metric: return "\(format(kg, digits: fractionDigits)) kg"
        case .imperial: return "\(format(kgToLb(kg), digits: fractionDigits)) lb"
        }
    }

    public static func formatFoodWeight(grams: Double, system: UnitSystem) -> String {
        switch system {
        case .metric: return "\(format(grams, digits: grams < 10 ? 1 : 0)) g"
        case .imperial: return "\(format(gramsToOunces(grams), digits: 1)) oz"
        }
    }

    public static func formatDuration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    public static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(max(0, digits))f", value)
    }

    /// Thousands-separated integer, locale-independent for deterministic tests.
    public static func formatInteger(_ value: Double) -> String {
        let n = Int(value.rounded())
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}

/// Every HealthKit data type the app touches — used for permission UI and authorization requests.
public enum HealthMetricType: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    // Read
    case steps, activeEnergy, restingEnergy, heartRate, restingHeartRate, hrv, sleep, workouts
    case bodyMass, bodyFat, leanBodyMass, bmi, water, vo2max, respiratoryRate, wristTemperature
    // Write (dietary)
    case dietaryEnergy, dietaryProtein, dietaryCarbs, dietaryFat, dietaryFiber, dietarySugar, dietarySodium

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable { case activity = "Activity", heart = "Heart", sleep = "Sleep", body = "Body", nutrition = "Nutrition", vitals = "Vitals" }

    public var group: Group {
        switch self {
        case .steps, .activeEnergy, .restingEnergy, .workouts, .vo2max: return .activity
        case .heartRate, .restingHeartRate, .hrv: return .heart
        case .sleep: return .sleep
        case .bodyMass, .bodyFat, .leanBodyMass, .bmi: return .body
        case .water, .dietaryEnergy, .dietaryProtein, .dietaryCarbs, .dietaryFat, .dietaryFiber, .dietarySugar, .dietarySodium: return .nutrition
        case .respiratoryRate, .wristTemperature: return .vitals
        }
    }

    public var displayName: String {
        switch self {
        case .steps: return "Steps"
        case .activeEnergy: return "Active energy"
        case .restingEnergy: return "Resting energy"
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .hrv: return "Heart rate variability"
        case .sleep: return "Sleep"
        case .workouts: return "Workouts"
        case .bodyMass: return "Weight"
        case .bodyFat: return "Body fat %"
        case .leanBodyMass: return "Lean body mass"
        case .bmi: return "BMI"
        case .water: return "Water"
        case .vo2max: return "VO₂ max"
        case .respiratoryRate: return "Respiratory rate"
        case .wristTemperature: return "Wrist temperature"
        case .dietaryEnergy: return "Dietary energy"
        case .dietaryProtein: return "Protein"
        case .dietaryCarbs: return "Carbohydrates"
        case .dietaryFat: return "Fat"
        case .dietaryFiber: return "Fiber"
        case .dietarySugar: return "Sugar"
        case .dietarySodium: return "Sodium"
        }
    }

    public var isReadable: Bool { true }

    /// Types the app writes back to Apple Health.
    public var isWritable: Bool {
        switch self {
        case .bodyMass, .bodyFat, .water, .dietaryEnergy, .dietaryProtein, .dietaryCarbs, .dietaryFat, .dietaryFiber, .dietarySugar, .dietarySodium:
            return true
        default: return false
        }
    }

    public static var readTypes: Set<HealthMetricType> { Set(allCases) }
    public static var writeTypes: Set<HealthMetricType> { Set(allCases.filter(\.isWritable)) }
}
