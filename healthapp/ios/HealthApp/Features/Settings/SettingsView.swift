import SwiftUI
import CoreModels
import DesignSystem

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink { DataSourcesView() } label: { row("Data sources", "Permissions & precedence", "point.3.filled.connected.trianglepath.dotted", .recover) }
                NavigationLink { DevicesView() } label: { row("Devices", "Food & body scales", "scalemass.fill", .body) }
                NavigationLink { NotificationsSettingsView() } label: { row("Notifications", "Reminders & alerts", "bell.badge.fill", .train) }
                NavigationLink { GoalsView() } label: { row("Goals", "Nutrition, steps, sleep", "target", .fuel) }
            }
            Section {
                NavigationLink { CycleTrackingView() } label: {
                    row("Cycle tracking", env.profile.cycleTrackingEnabled ? "On" : "Off (optional)", "circle.dashed", .protein)
                }
                Picker(selection: Binding(get: { env.profile.units }, set: { u in
                    var p = env.profile; p.units = u
                    Task { await env.updateProfile(p) }
                })) {
                    Text("Metric").tag(UnitSystem.metric)
                    Text("Imperial").tag(UnitSystem.imperial)
                } label: { row("Units", nil, "ruler", .body) }
            }
            Section {
                NavigationLink { AccountView() } label: { row("Account & privacy", env.session?.email, "person.crop.circle", .secondary) }
            }
            Section {
                LabeledContent("Mode", value: env.mode == .demo ? "Demo data" : "Live")
                if let sync = env.lastSync {
                    LabeledContent("Last sync", value: sync.finishedAt.formatted(date: .omitted, time: .shortened))
                }
                Button(env.isSyncing ? "Syncing…" : "Sync now") { Task { await env.syncNow() } }
                    .disabled(env.isSyncing)
            } footer: {
                Text(env.mode == .demo
                     ? "Demo mode uses 90 days of generated data. Add backend values to Config.xcconfig to use your own data."
                     : "Food you log offline is stored encrypted on this device and synced automatically.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func row(_ title: String, _ subtitle: String?, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol).foregroundStyle(.white).frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct GoalsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var goals = Goals.default
    @State private var useCalorieTarget = false

    var body: some View {
        Form {
            Section {
                Picker("Focus", selection: $goals.mode) {
                    ForEach(GoalMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Set a calorie target", isOn: $useCalorieTarget)
                if useCalorieTarget {
                    Stepper("Calories: \(Int(goals.calorieTarget ?? 2200)) kcal", value: Binding(get: { goals.calorieTarget ?? 2200 }, set: { goals.calorieTarget = $0 }), in: 1200...5000, step: 50)
                }
            } footer: {
                Text("Without a calorie target, Today compares what you eat with what you burn instead of counting down a number.")
            }
            Section("Macros (g per day)") {
                Stepper("Protein: \(Int(goals.proteinG)) g", value: $goals.proteinG, in: 30...300, step: 5)
                Stepper("Carbs: \(Int(goals.carbsG)) g", value: $goals.carbsG, in: 50...600, step: 10)
                Stepper("Fat: \(Int(goals.fatG)) g", value: $goals.fatG, in: 20...250, step: 5)
                Stepper("Fiber: \(Int(goals.fiberG)) g", value: $goals.fiberG, in: 10...80, step: 1)
            }
            Section("Daily") {
                Stepper("Water: \(Int(goals.waterMl)) ml", value: $goals.waterMl, in: 500...6000, step: 250)
                Stepper("Steps: \(Int(goals.stepGoal))", value: $goals.stepGoal, in: 1000...30000, step: 500)
                Stepper("Sleep: \(goals.sleepHours.formatted(.number.precision(.fractionLength(0...1)))) h", value: $goals.sleepHours, in: 5...10, step: 0.5)
            }
        }
        .navigationTitle("Goals")
        .onAppear { goals = env.goals; useCalorieTarget = env.goals.calorieTarget != nil }
        .onDisappear {
            var g = goals
            if !useCalorieTarget { g.calorieTarget = nil }
            if g != env.goals { Task { await env.updateGoals(g) } }
        }
    }
}

struct NotificationsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var authorized: Bool?

    var body: some View {
        @Bindable var env = env
        Form {
            Section {
                Toggle("Meal reminders", isOn: $env.notificationPrefs.mealReminders)
                if env.notificationPrefs.mealReminders {
                    ForEach(env.notificationPrefs.mealReminderMinutes.indices, id: \.self) { i in
                        DatePicker(i == 0 ? "Breakfast" : (i == 1 ? "Lunch" : "Dinner"),
                                   selection: Binding(get: { Self.date(minutes: env.notificationPrefs.mealReminderMinutes[i]) },
                                                      set: { env.notificationPrefs.mealReminderMinutes[i] = Self.minutes($0) }),
                                   displayedComponents: .hourAndMinute)
                    }
                }
                Toggle("Hydration", isOn: $env.notificationPrefs.hydration)
                Toggle("Protein goal progress", isOn: $env.notificationPrefs.proteinGoalProgress)
            } header: { Text("Reminders") }
            Section {
                Toggle("Low recovery alerts", isOn: $env.notificationPrefs.lowRecoveryAlerts)
                Toggle("Sleep consistency", isOn: $env.notificationPrefs.sleepConsistency)
                Toggle("Device sync failures", isOn: $env.notificationPrefs.deviceSyncFailures)
            } header: { Text("Alerts") } footer: {
                Text("Alerts are informational. Low recovery alerts use your readiness score; they're not medical warnings.")
            }
            if authorized == false {
                Section { Text("Notifications are turned off for HealthApp in iOS Settings.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Notifications")
        .task { authorized = try? await env.notifications.requestAuthorization() }
        .onChange(of: env.notificationPrefs) { _, _ in Task { await env.applyNotificationPrefs() } }
    }

    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

struct CycleTrackingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var flow = "none"
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable cycle tracking", isOn: Binding(get: { env.profile.cycleTrackingEnabled }, set: { on in
                    var p = env.profile; p.cycleTrackingEnabled = on
                    Task { await env.updateProfile(p) }
                }))
            } footer: {
                Text("Optional. When on, you can log your cycle and compare it with weight and recovery in Trends. Cycle data is only stored when enabled and is deleted with your account.")
            }
            if env.profile.cycleTrackingEnabled {
                Section("Today") {
                    Picker("Flow", selection: $flow) {
                        Text("None").tag("none")
                        Text("Light").tag("light")
                        Text("Medium").tag("medium")
                        Text("Heavy").tag("heavy")
                    }
                    Button(saved ? "Saved" : "Save") {
                        Task {
                            try? await env.repository.saveCycleEntry(CycleEntry(date: .today(), flow: flow == "none" ? nil : flow))
                            saved = true
                        }
                    }
                }
            }
        }
        .navigationTitle("Cycle tracking")
    }
}
