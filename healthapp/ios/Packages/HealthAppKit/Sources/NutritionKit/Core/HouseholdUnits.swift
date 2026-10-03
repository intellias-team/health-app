import Foundation
import CoreModels

/// Household and label units with conversion to grams.
public enum HouseholdUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case gram = "g", kilogram = "kg", ounce = "oz", pound = "lb"
    case milliliter = "ml", liter = "l", fluidOunce = "fl oz", cup, tablespoon = "tbsp", teaspoon = "tsp"
    case serving, piece

    public var id: String { rawValue }

    public var isVolume: Bool {
        switch self {
        case .milliliter, .liter, .fluidOunce, .cup, .tablespoon, .teaspoon: return true
        default: return false
        }
    }

    /// Millilitres per unit for volume units (US customary cup/tbsp/tsp).
    public var milliliters: Double? {
        switch self {
        case .milliliter: return 1
        case .liter: return 1000
        case .fluidOunce: return Units.mlPerFluidOunce
        case .cup: return 236.5882365
        case .tablespoon: return 14.78676478125
        case .teaspoon: return 4.92892159375
        default: return nil
        }
    }
}

public enum UnitConversionError: Error, Equatable {
    case missingPortion(HouseholdUnit)
}

public enum UnitConverter {
    /// Converts `amount` of `unit` into grams.
    /// - Parameters:
    ///   - densityGPerMl: density for volume units (defaults to water, 1 g/ml).
    ///   - portionGrams: grams per serving/piece (from `FoodDetail.portions`).
    public static func grams(amount: Double, unit: HouseholdUnit, densityGPerMl: Double = 1.0, portionGrams: Double? = nil) throws -> Double {
        switch unit {
        case .gram: return amount
        case .kilogram: return amount * 1000
        case .ounce: return amount * Units.gramsPerOunce
        case .pound: return amount * Units.gramsPerPound
        case .serving, .piece:
            guard let portionGrams else { throw UnitConversionError.missingPortion(unit) }
            return amount * portionGrams
        default:
            return amount * (unit.milliliters ?? 1) * densityGPerMl
        }
    }

    /// Converts grams into `unit`.
    public static func amount(fromGrams grams: Double, unit: HouseholdUnit, densityGPerMl: Double = 1.0, portionGrams: Double? = nil) throws -> Double {
        let one = try self.grams(amount: 1, unit: unit, densityGPerMl: densityGPerMl, portionGrams: portionGrams)
        return grams / one
    }
}
