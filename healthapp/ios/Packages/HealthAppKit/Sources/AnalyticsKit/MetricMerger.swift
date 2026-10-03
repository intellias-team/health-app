import Foundation
import CoreModels

/// Client-side mirror of the backend's `services/merge.js` source-precedence merge (docs/02 §2.2.3).
public enum MetricMerger {
    public static func merge(_ bySource: [MetricSource: MetricValues], settings: DataSourceSettings = DataSourceSettings()) -> MetricValues {
        var merged = MetricValues()
        for key in MetricKey.allCases {
            for source in settings.effectivePrecedence(for: key) {
                if let values = bySource[source], values.has(key) {
                    merged.take(key, from: values)
                    break
                }
            }
        }
        // Fields without an explicit MetricKey (none today) would be merged here.
        return merged
    }

    public static func merge(days: [DailyMetrics], settings: DataSourceSettings = DataSourceSettings()) -> [MergedDay] {
        let grouped = Dictionary(grouping: days, by: \.date)
        return grouped.keys.sorted().map { date in
            var bySource: [MetricSource: MetricValues] = [:]
            for d in grouped[date] ?? [] { bySource[d.source] = d.metrics }
            let stringKeyed = Dictionary(uniqueKeysWithValues: bySource.map { ($0.key.rawValue, $0.value) })
            return MergedDay(date: date, merged: merge(bySource, settings: settings), bySource: stringKeyed)
        }
    }
}
