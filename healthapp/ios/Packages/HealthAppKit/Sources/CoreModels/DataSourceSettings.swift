import Foundation

/// A data source the user can grant or revoke per metric in Settings → Data Sources.
public struct DataSourceDescriptor: Hashable, Sendable, Identifiable {
    /// Connection provider id: "healthkit", "oura", "bodyscale:<id>", "foodscale:<id>".
    public var id: String
    public var source: MetricSource
    public var displayName: String
    public var metrics: [String]

    public init(id: String, source: MetricSource, displayName: String, metrics: [String]) {
        self.id = id; self.source = source; self.displayName = displayName; self.metrics = metrics
    }

    public static let healthKit = DataSourceDescriptor(id: "healthkit", source: .healthkit, displayName: "Apple Health",
                                                       metrics: HealthMetricType.allCases.map(\.rawValue))
    public static let oura = DataSourceDescriptor(id: "oura", source: .oura, displayName: "Oura Ring",
                                                  metrics: [MetricKey.sleepMinutes, .sleepStages, .sleepScore, .readinessScore, .activityScore,
                                                            .hrvMs, .restingHr, .tempDeviationC, .respiratoryRate, .spo2Pct, .steps, .activeKcal].map(\.rawValue) + ["workouts"])
    public static let bodyScale = DataSourceDescriptor(id: "bodyscale:default", source: .bodyscale, displayName: "Smart body scale",
                                                       metrics: ["weightKg", "bodyFatPct", "muscleMassKg", "leanMassKg", "bmi", "waterPct", "boneMassKg", "visceralFat"])
    public static let foodScale = DataSourceDescriptor(id: "foodscale:default", source: .foodscale, displayName: "Bluetooth food scale",
                                                       metrics: ["foodWeight"])
}

/// User choices: which metrics each source may contribute, and per-metric source precedence overrides.
/// Persisted locally and mirrored to `PUT /v1/connections/{provider}`.
public struct DataSourceSettings: Codable, Hashable, Sendable {
    /// provider id → enabled metric ids. A missing provider means "all metrics enabled".
    public var enabledMetrics: [String: Set<String>]
    /// Metric key → ordered sources (first wins). Missing = `MetricKey.defaultPrecedence`.
    public var precedence: [MetricKey: [MetricSource]]

    public init(enabledMetrics: [String: Set<String>] = [:], precedence: [MetricKey: [MetricSource]] = [:]) {
        self.enabledMetrics = enabledMetrics; self.precedence = precedence
    }

    public func isEnabled(provider: String, metric: String) -> Bool {
        guard let set = enabledMetrics[provider] else { return true }
        return set.contains(metric)
    }

    public mutating func setEnabled(_ enabled: Bool, provider: String, metric: String, allMetrics: [String]) {
        var set = enabledMetrics[provider] ?? Set(allMetrics)
        if enabled { set.insert(metric) } else { set.remove(metric) }
        enabledMetrics[provider] = set
    }

    public func precedence(for key: MetricKey) -> [MetricSource] { precedence[key] ?? key.defaultPrecedence }

    /// Sources first in precedence that the user has also enabled for `key`.
    public func effectivePrecedence(for key: MetricKey) -> [MetricSource] {
        precedence(for: key).filter { source in
            switch source {
            case .oura: return isEnabled(provider: "oura", metric: key.rawValue)
            default: return true
            }
        }
    }
}
