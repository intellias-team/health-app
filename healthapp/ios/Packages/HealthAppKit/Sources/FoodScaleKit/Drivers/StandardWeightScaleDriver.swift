import Foundation

/// Driver for any scale implementing the Bluetooth SIG Weight Scale Service (0x181D) with the
/// Weight Measurement characteristic (0x2A9D, indicate).
///
/// Note the spec's resolution: 5 g (SI) or 0.01 lb ≈ 4.5 g (imperial). That is coarse for food, so
/// vendor drivers with gram resolution score higher when both match.
public struct StandardWeightScaleDriver: FoodScaleDriver {
    public init() {}

    public var id: String { "sig-weight-scale" }
    public var displayName: String { "Bluetooth Weight Scale (standard)" }
    public var serviceUUIDs: [String] { [BLEUUID.weightScaleService] }
    public var notifyCharacteristicUUIDs: [String] { [BLEUUID.weightMeasurement] }

    public func matchScore(for ad: ScaleAdvertisement) -> Int {
        ad.serviceUUIDs.contains(BLEUUID.weightScaleService) ? 10 : 0
    }

    public func parse(characteristicUUID: String, value: Data, receivedAt: Date) -> WeightReading? {
        guard BLEUUID.equal(characteristicUUID, BLEUUID.weightMeasurement),
              let m = WeightMeasurementParser.parse(value) else { return nil }
        // 0x2A9D is only sent for completed (settled) measurements.
        return WeightReading(grams: m.grams, isStable: true, unit: m.isImperial ? .pounds : .kilograms, timestamp: receivedAt)
    }
}
