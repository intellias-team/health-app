import XCTest
@testable import FoodScaleKit

final class FoodScaleKitTests: XCTestCase {
    // MARK: 0x2A9D Weight Measurement

    func testSIWeight() throws {
        // flags 0x00 (SI), weight 0x3A98 = 15000 × 0.005 kg = 75.000 kg
        let m = try XCTUnwrap(WeightMeasurementParser.parse(Data([0x00, 0x98, 0x3A])))
        XCTAssertFalse(m.isImperial)
        XCTAssertEqual(m.weightKg, 75.0, accuracy: 1e-9)
        XCTAssertEqual(m.grams, 75_000, accuracy: 1e-6)
        XCTAssertNil(m.timestamp); XCTAssertNil(m.userId); XCTAssertNil(m.bmi)
    }

    func testSIResolutionIsFiveGrams() throws {
        // raw 63 → 0.315 kg (a food item on an SIG-compliant scale)
        let m = try XCTUnwrap(WeightMeasurementParser.parse(Data([0x00, 63, 0])))
        XCTAssertEqual(m.grams, 315, accuracy: 1e-9)
    }

    func testImperialWeight() throws {
        // flags 0x01 (imperial), raw 16535 × 0.01 lb = 165.35 lb = 75.0012 kg
        let raw: UInt16 = 16535
        let m = try XCTUnwrap(WeightMeasurementParser.parse(Data([0x01, UInt8(raw & 0xFF), UInt8(raw >> 8)])))
        XCTAssertTrue(m.isImperial)
        XCTAssertEqual(m.weightKg, 165.35 * 0.45359237, accuracy: 1e-9)
    }

    func testAllOptionalFields() throws {
        // flags: imperial | timestamp | userID | BMI+height = 0x0F
        var bytes: [UInt8] = [0x0F]
        bytes += [0x10, 0x27]                             // 10000 × 0.01 lb = 100 lb
        bytes += [0xEA, 0x07, 10, 3, 7, 30, 15]           // 2026-10-03 07:30:15
        bytes += [0x02]                                   // user 2
        bytes += [0xF5, 0x00]                             // BMI 24.5
        bytes += [0xB8, 0x02]                             // height 696 × 0.1 in = 69.6 in
        let m = try XCTUnwrap(WeightMeasurementParser.parse(Data(bytes)))
        XCTAssertEqual(m.weightKg, 45.359237, accuracy: 1e-9)
        XCTAssertEqual(m.timestamp?.year, 2026); XCTAssertEqual(m.timestamp?.month, 10); XCTAssertEqual(m.timestamp?.day, 3)
        XCTAssertEqual(m.timestamp?.hour, 7); XCTAssertEqual(m.timestamp?.minute, 30); XCTAssertEqual(m.timestamp?.second, 15)
        XCTAssertEqual(m.userId, 2)
        XCTAssertEqual(m.bmi ?? 0, 24.5, accuracy: 1e-9)
        XCTAssertEqual(m.heightM ?? 0, 69.6 * 0.0254, accuracy: 1e-9)
    }

    func testSIHeightAndUnknownUser() throws {
        let bytes: [UInt8] = [0x0C, 0x98, 0x3A, 0xFF, 0xF5, 0x00, 0xE0, 0x06] // user 0xFF, BMI 24.5, height 1760 mm
        let m = try XCTUnwrap(WeightMeasurementParser.parse(Data(bytes)))
        XCTAssertNil(m.userId)
        XCTAssertEqual(m.heightM ?? 0, 1.76, accuracy: 1e-9)
    }

    func testInvalidFrames() {
        XCTAssertNil(WeightMeasurementParser.parse(Data()))
        XCTAssertNil(WeightMeasurementParser.parse(Data([0x00, 0x01])), "truncated weight")
        XCTAssertNil(WeightMeasurementParser.parse(Data([0x00, 0xFF, 0xFF])), "measurement unsuccessful")
        XCTAssertNil(WeightMeasurementParser.parse(Data([0x02, 0x98, 0x3A, 0xEA])), "truncated timestamp")
    }

    func testEncodeRoundTrip() throws {
        let si = try XCTUnwrap(WeightMeasurementParser.parse(WeightMeasurementParser.encode(weightKg: 0.42)))
        XCTAssertEqual(si.grams, 420, accuracy: 1e-9)
        let imp = try XCTUnwrap(WeightMeasurementParser.parse(WeightMeasurementParser.encode(weightKg: 0.42, imperial: true)))
        XCTAssertEqual(imp.grams, 420, accuracy: 3)
    }

    func testStandardDriverParsesOnlyItsCharacteristic() throws {
        let d = StandardWeightScaleDriver()
        let full = "00002A9D-0000-1000-8000-00805F9B34FB"
        let r = try XCTUnwrap(d.parse(characteristicUUID: full, value: Data([0x00, 0x98, 0x3A]), receivedAt: Date()))
        XCTAssertTrue(r.isStable)
        XCTAssertEqual(r.unit, .kilograms)
        XCTAssertNil(d.parse(characteristicUUID: "2A9C", value: Data([0x00, 0x98, 0x3A]), receivedAt: Date()))
    }

    // MARK: Vendor template & registry

    func testExampleVendorFrame() throws {
        let d = ExampleVendorScaleDriver()
        let frame = ExampleVendorScaleDriver.makeWeightFrame(grams: 312.4, stable: true)
        let r = try XCTUnwrap(d.parse(characteristicUUID: "FFE1", value: frame, receivedAt: Date()))
        XCTAssertEqual(r.grams, 312.4, accuracy: 1e-9)
        XCTAssertTrue(r.isStable)
        let neg = try XCTUnwrap(d.parse(characteristicUUID: "FFE1", value: ExampleVendorScaleDriver.makeWeightFrame(grams: -5, stable: false), receivedAt: Date()))
        XCTAssertEqual(neg.grams, -5)
        var corrupt = [UInt8](frame); corrupt[3] ^= 0x01
        XCTAssertNil(d.parse(characteristicUUID: "FFE1", value: Data(corrupt), receivedAt: Date()), "checksum")
        let tare = try XCTUnwrap(d.tareCommand())
        XCTAssertEqual([UInt8](tare.data), [0xAC, 0x01, 0x00, 0xAD] as [UInt8])
    }

    func testRegistryPicksMostSpecificDriver() {
        let registry = FoodScaleRegistry.standard
        let sig = ScaleAdvertisement(localName: "Scale", serviceUUIDs: ["0000181d-0000-1000-8000-00805f9b34fb"])
        XCTAssertEqual(registry.driver(for: sig)?.id, "sig-weight-scale")
        let acme = ScaleAdvertisement(localName: "ACME-KS 2", serviceUUIDs: ["181D"])
        XCTAssertEqual(registry.driver(for: acme)?.id, "example-acme-kitchen")
        XCTAssertNil(registry.driver(for: ScaleAdvertisement(localName: "Headphones")))
        XCTAssertEqual(ScaleAdvertisement(localName: nil, manufacturerData: Data([0x4C, 0x00, 0x01])).companyIdentifier, 0x004C)
    }

    func testMockDriverAndSignal() throws {
        let d = MockFoodScaleDriver()
        let r = try XCTUnwrap(d.parse(characteristicUUID: MockFoodScaleDriver.notifyChar, value: MockFoodScaleDriver.frame(grams: 123.5), receivedAt: Date()))
        XCTAssertEqual(r.grams, 123.5, accuracy: 1e-4)

        var signal = MockScaleSignal(targetGrams: 250, placedAt: 0.5, noise: 0.3, seed: 1)
        var detector = StableWeightDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var stable: Double?
        for i in 0..<60 { // 6 s at 10 Hz
            let t = Double(i) / 10
            if let s = detector.add(grams: signal.grams(at: t), at: t0.addingTimeInterval(t)) { stable = s; break }
        }
        XCTAssertEqual(try XCTUnwrap(stable), 250, accuracy: 1.0)
    }

    // MARK: Stable detection

    func testStableAfterOneSecondWithinTolerance() {
        var d = StableWeightDetector(tolerance: 1, window: 1, minReadings: 4)
        let t0 = Date(timeIntervalSince1970: 0)
        var result: Double?
        let values = [100.2, 100.6, 99.8, 100.1, 100.4, 99.9, 100.0, 100.3, 100.1, 100.2, 100.0]
        for (i, v) in values.enumerated() {
            if let r = d.add(grams: v, at: t0.addingTimeInterval(Double(i) * 0.1)) { result = r; XCTAssertGreaterThanOrEqual(i, 8, "needs ≥ 0.75 s span") ; break }
        }
        XCTAssertEqual(result ?? 0, 100.1, accuracy: 0.2)
    }

    func testNotStableWhileMoving() {
        var d = StableWeightDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<30 {
            XCTAssertNil(d.add(grams: Double(i) * 3, at: t0.addingTimeInterval(Double(i) * 0.1)))
        }
    }

    func testEmptyPlatformNeverStable() {
        var d = StableWeightDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<20 { XCTAssertNil(d.add(grams: 0.1, at: t0.addingTimeInterval(Double(i) * 0.1))) }
    }

    func testReportsEachPlateauOnce() {
        var d = StableWeightDetector()
        let t0 = Date(timeIntervalSince1970: 0)
        var reports: [Double] = []
        // plateau 1 (200 g) for 2 s, then add food → plateau 2 (350 g) for 2 s
        for i in 0..<20 { if let r = d.add(grams: 200, at: t0.addingTimeInterval(Double(i) * 0.1)) { reports.append(r) } }
        for i in 20..<40 { if let r = d.add(grams: 350, at: t0.addingTimeInterval(Double(i) * 0.1)) { reports.append(r) } }
        XCTAssertEqual(reports, [200, 350])
    }

    func testUUIDNormalisation() {
        XCTAssertEqual(BLEUUID.normalize("00002a9d-0000-1000-8000-00805f9b34fb"), "2A9D")
        XCTAssertEqual(BLEUUID.normalize("2a9d"), "2A9D")
        XCTAssertEqual(BLEUUID.normalize("12345678-1234-1234-1234-1234567890AB"), "12345678-1234-1234-1234-1234567890AB")
    }
}
