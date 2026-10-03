import SwiftUI
import CoreModels
import DesignSystem

/// Per-source, per-metric permission toggles + source precedence.
/// Toggles are the app-level switch (mirrored to `PUT /v1/connections/{provider}`); iOS-level HealthKit
/// permissions are requested separately and can only be changed by the user in the Health app.
struct DataSourcesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var ouraBusy = false
    @State private var message: String?

    var body: some View {
        List {
            healthKitSection
            ouraSection
            metricsSection(DataSourceDescriptor.bodyScale, footer: "Weight and body composition from smart scales, read via Apple Health (any scale app that syncs to Health).")
            metricsSection(DataSourceDescriptor.foodScale, footer: "Bluetooth food scales give exact grams. Pair one under Devices.")
            Section {
                NavigationLink("Source precedence") { PrecedenceView() }
            } footer: {
                Text("When two sources report the same metric, the first enabled source in the list wins. By default Oura is used for sleep, readiness, HRV and temperature; Apple Health for steps, energy, workouts and body.")
            }
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Data sources")
    }

    private func status(_ provider: String) -> Connection? { env.connections.first { $0.provider == provider } }

    private var healthKitSection: some View {
        Section {
            HStack {
                Label("Apple Health", systemImage: "heart.text.square.fill").foregroundStyle(Color.train)
                Spacer()
                Text(env.health.isAvailable ? "Available" : "Unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Button("Request Health access") {
                Task {
                    do {
                        try await env.health.requestAuthorization(read: HealthMetricType.readTypes, write: HealthMetricType.writeTypes)
                        message = "Health permissions updated. You can review them in the Health app → Sharing → Apps."
                    } catch { message = error.localizedDescription }
                }
            }
            Toggle("Write meals to Apple Health", isOn: Binding(get: { env.writeMealsToHealth }, set: { env.writeMealsToHealth = $0 }))
            ForEach(HealthMetricType.Group.allCases, id: \.self) { group in
                DisclosureGroup(group.rawValue) {
                    ForEach(HealthMetricType.allCases.filter { $0.group == group }) { type in
                        Toggle(isOn: binding(provider: DataSourceDescriptor.healthKit, metric: type.rawValue)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(type.displayName)
                                Text(type.isWritable ? "Read & write" : "Read").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } footer: {
            Text("Turning a metric off here stops HealthApp from using or uploading it, even if iOS access is granted.")
        }
    }

    private var ouraSection: some View {
        let connection = status("oura")
        let connected = connection?.status == .connected
        return Section {
            HStack {
                Label("Oura Ring", systemImage: "circle.circle").foregroundStyle(Color.recover)
                Spacer()
                Text(connected ? "Connected" : "Not connected").font(.caption).foregroundStyle(.secondary)
            }
            if let last = connection?.lastSyncAt {
                LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let err = connection?.lastError { Text(err).font(.caption).foregroundStyle(Color.train) }
            if connected {
                Button(ouraBusy ? "Syncing…" : "Sync now") {
                    Task { ouraBusy = true; defer { ouraBusy = false }
                        do { let r = try await env.oura.sync(from: nil, to: nil); message = "Oura: \(r.daysUpserted) days, \(r.workoutsUpserted) workouts updated."; env.dataVersion += 1 }
                        catch { message = error.localizedDescription }
                    }
                }
                .disabled(ouraBusy)
                ForEach(DataSourceDescriptor.oura.metrics, id: \.self) { metric in
                    Toggle(MetricKey(rawValue: metric)?.displayName ?? metric.capitalized,
                           isOn: binding(provider: DataSourceDescriptor.oura, metric: metric))
                }
                Button("Disconnect Oura", role: .destructive) {
                    Task {
                        do { try await env.oura.disconnect(); await env.loadAccount() } catch { message = error.localizedDescription }
                    }
                }
            } else {
                Button(ouraBusy ? "Connecting…" : "Connect Oura") {
                    Task { ouraBusy = true; defer { ouraBusy = false }
                        do { try await env.oura.connect(); await env.loadAccount(); env.dataVersion += 1 }
                        catch { message = error.localizedDescription }
                    }
                }
                .disabled(ouraBusy)
            }
        } footer: {
            Text("Oura data is fetched by the HealthApp server with your permission; your Oura credentials never touch this device.")
        }
    }

    private func metricsSection(_ source: DataSourceDescriptor, footer: String) -> some View {
        Section {
            DisclosureGroup(source.displayName) {
                ForEach(source.metrics, id: \.self) { metric in
                    Toggle(Self.label(metric), isOn: binding(provider: source, metric: metric))
                }
            }
        } footer: { Text(footer) }
    }

    private func binding(provider: DataSourceDescriptor, metric: String) -> Binding<Bool> {
        Binding(get: { env.dataSourceSettings.isEnabled(provider: provider.id, metric: metric) },
                set: { env.setMetric(metric, enabled: $0, for: provider) })
    }

    static func label(_ metric: String) -> String {
        switch metric {
        case "weightKg": return "Weight"
        case "bodyFatPct": return "Body fat %"
        case "muscleMassKg": return "Muscle mass"
        case "leanMassKg": return "Lean mass"
        case "bmi": return "BMI"
        case "waterPct": return "Body water %"
        case "boneMassKg": return "Bone mass"
        case "visceralFat": return "Visceral fat"
        case "foodWeight": return "Food weight"
        default: return metric
        }
    }
}

struct PrecedenceView: View {
    @Environment(AppEnvironment.self) private var env
    private let keys: [MetricKey] = [.sleepMinutes, .sleepStages, .sleepScore, .readinessScore, .hrvMs, .restingHr, .tempDeviationC, .respiratoryRate, .steps, .activeKcal, .restingKcal]

    var body: some View {
        List {
            ForEach(keys) { key in
                let order = env.dataSourceSettings.precedence(for: key).filter { $0 != .manual }
                Picker(key.displayName, selection: Binding(get: { order.first ?? .healthkit },
                                                           set: { first in
                    let rest = [MetricSource.healthkit, .oura].filter { $0 != first }
                    env.setPrecedence([.manual, first] + rest, for: key)
                })) {
                    Text("Apple Health first").tag(MetricSource.healthkit)
                    Text("Oura first").tag(MetricSource.oura)
                }
            }
        }
        .navigationTitle("Source precedence")
    }
}
