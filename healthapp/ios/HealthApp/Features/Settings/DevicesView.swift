import SwiftUI
import CoreModels
import FoodScaleKit
import DesignSystem

/// Pair a Bluetooth food scale; see how body scales connect.
struct DevicesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let scale = env.foodScale
        List {
            Section {
                switch scale.state {
                case .connected(let name):
                    LabeledContent("Connected", value: name)
                    if let reading = scale.latestReading {
                        LabeledContent("Live weight", value: "\(Fmt.one(reading.grams)) g")
                    }
                    Button("Tare") { scale.tare() }
                    Button("Disconnect", role: .destructive) { scale.disconnect() }
                case .scanning:
                    HStack { ProgressView(); Text("Scanning…") }
                    Button("Stop") { scale.stopScan() }
                case .connecting(let name):
                    HStack { ProgressView(); Text("Connecting to \(name)…") }
                case .poweredOff:
                    Text("Bluetooth is off.")
                case .unauthorized:
                    Text("Bluetooth permission denied. Enable it in iOS Settings → HealthApp.")
                case .unsupported:
                    Text("Bluetooth isn't supported on this device.")
                case .failed(let m):
                    Text(m).foregroundStyle(Color.train)
                    Button("Scan for scales") { scale.startScan() }
                case .idle:
                    Button("Scan for scales") { scale.startScan() }
                }
                ForEach(scale.discovered) { found in
                    Button { scale.connect(found) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(found.name)
                                Text("\(found.driverName) · \(found.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "link")
                        }
                    }
                }
            } header: { Text("Food scale") } footer: {
                Text(scale.simulate ? "Running in the Simulator: a simulated scale is used." :
                        "Supported: scales implementing the Bluetooth Weight Scale profile, plus vendor drivers listed below.")
            }
            Section("Supported scale drivers") {
                ForEach(scale.registry.drivers, id: \.id) { d in
                    VStack(alignment: .leading) {
                        Text(d.displayName)
                        Text("Services: \(d.serviceUUIDs.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(Array(env.bodyScales.enumerated()), id: \.offset) { _, provider in
                    Label(provider.displayName, systemImage: "scalemass")
                }
            } header: { Text("Body scale") } footer: {
                Text("Weigh in with your scale's own app and let it sync to Apple Health — HealthApp reads weight, body fat and lean mass from there. Direct Bluetooth body-scale support is planned.")
            }
        }
        .navigationTitle("Devices")
    }
}
