import Foundation

public enum UnitSystem: String, Codable, Hashable, Sendable, CaseIterable { case metric, imperial }

public enum BiologicalSex: String, Codable, Hashable, Sendable, CaseIterable { case female, male, other, unspecified }

/// `PROFILE` item.
public struct Profile: Codable, Hashable, Sendable {
    public var displayName: String?
    public var birthYear: Int?
    public var sex: BiologicalSex?
    public var heightCm: Double?
    public var units: UnitSystem
    public var timezone: String
    public var cycleTrackingEnabled: Bool
    public var createdAt: Date?

    public init(displayName: String? = nil, birthYear: Int? = nil, sex: BiologicalSex? = nil, heightCm: Double? = nil,
                units: UnitSystem = .metric, timezone: String = TimeZone.current.identifier,
                cycleTrackingEnabled: Bool = false, createdAt: Date? = nil) {
        self.displayName = displayName; self.birthYear = birthYear; self.sex = sex; self.heightCm = heightCm
        self.units = units; self.timezone = timezone; self.cycleTrackingEnabled = cycleTrackingEnabled; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case displayName, birthYear, sex, heightCm, units, timezone, cycleTrackingEnabled, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        sex = try c.decodeIfPresent(BiologicalSex.self, forKey: .sex)
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        units = try c.decodeIfPresent(UnitSystem.self, forKey: .units) ?? .metric
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? TimeZone.current.identifier
        cycleTrackingEnabled = try c.decodeIfPresent(Bool.self, forKey: .cycleTrackingEnabled) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public enum GoalMode: String, Codable, Hashable, Sendable, CaseIterable {
    case maintain, gain, loseGently = "lose_gently", performance

    public var displayName: String {
        switch self {
        case .maintain: return "Maintain"
        case .gain: return "Build"
        case .loseGently: return "Lose gently"
        case .performance: return "Performance"
        }
    }
}

/// `GOALS` item.
public struct Goals: Codable, Hashable, Sendable {
    public var calorieTarget: Double?
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double
    public var waterMl: Double
    public var stepGoal: Double
    public var sleepHours: Double
    public var mode: GoalMode

    public init(calorieTarget: Double? = nil, proteinG: Double = 120, carbsG: Double = 250, fatG: Double = 75,
                fiberG: Double = 30, waterMl: Double = 2500, stepGoal: Double = 8000, sleepHours: Double = 8,
                mode: GoalMode = .maintain) {
        self.calorieTarget = calorieTarget; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.fiberG = fiberG; self.waterMl = waterMl; self.stepGoal = stepGoal; self.sleepHours = sleepHours; self.mode = mode
    }

    public static let `default` = Goals()
}

public enum ConnectionStatus: String, Codable, Hashable, Sendable { case connected, revoked, error, notConnected = "not_connected" }

/// `CONNECTION#<provider>` item — source connection + user-level per-metric permission switches.
public struct Connection: Codable, Hashable, Sendable, Identifiable {
    /// "healthkit", "oura", "bodyscale:<id>", "foodscale:<id>"
    public var provider: String
    public var status: ConnectionStatus
    public var scopes: [String]
    public var enabledMetrics: [String]
    public var lastSyncAt: Date?
    public var lastError: String?

    public var id: String { provider }

    public init(provider: String, status: ConnectionStatus, scopes: [String] = [], enabledMetrics: [String] = [],
                lastSyncAt: Date? = nil, lastError: String? = nil) {
        self.provider = provider; self.status = status; self.scopes = scopes; self.enabledMetrics = enabledMetrics
        self.lastSyncAt = lastSyncAt; self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey { case provider, status, scopes, enabledMetrics, lastSyncAt, lastError }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        status = (try? c.decode(ConnectionStatus.self, forKey: .status)) ?? .notConnected
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        enabledMetrics = try c.decodeIfPresent([String].self, forKey: .enabledMetrics) ?? []
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Per-device notification preferences (`DEVICE#<id>.notificationPrefs`).
public struct NotificationPreferences: Codable, Hashable, Sendable {
    public var mealReminders: Bool
    public var hydration: Bool
    public var lowRecoveryAlerts: Bool
    public var sleepConsistency: Bool
    public var proteinGoalProgress: Bool
    public var deviceSyncFailures: Bool
    /// Minutes after midnight for breakfast/lunch/dinner reminders.
    public var mealReminderMinutes: [Int]

    public init(mealReminders: Bool = true, hydration: Bool = false, lowRecoveryAlerts: Bool = true,
                sleepConsistency: Bool = false, proteinGoalProgress: Bool = true, deviceSyncFailures: Bool = true,
                mealReminderMinutes: [Int] = [8 * 60 + 30, 12 * 60 + 30, 19 * 60]) {
        self.mealReminders = mealReminders; self.hydration = hydration; self.lowRecoveryAlerts = lowRecoveryAlerts
        self.sleepConsistency = sleepConsistency; self.proteinGoalProgress = proteinGoalProgress
        self.deviceSyncFailures = deviceSyncFailures; self.mealReminderMinutes = mealReminderMinutes
    }
}

public struct DeviceRegistration: Codable, Hashable, Sendable {
    public var id: String
    public var apnsToken: String
    public var platform: String
    public var appVersion: String
    public var notificationPrefs: NotificationPreferences
    public init(id: String, apnsToken: String, platform: String = "ios", appVersion: String, notificationPrefs: NotificationPreferences) {
        self.id = id; self.apnsToken = apnsToken; self.platform = platform; self.appVersion = appVersion; self.notificationPrefs = notificationPrefs
    }
}
