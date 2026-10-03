import SwiftUI
import CoreModels
import DesignSystem
import NotificationsKit

/// Welcome → sign in → connect sources step by step → notifications.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $step) {
                    welcome.tag(0)
                    signIn.tag(1)
                    connectHealth.tag(2)
                    connectOura.tag(3)
                    notifications.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .animation(.easeInOut, value: step)
            }
            .background(Color.surface)
        }
        .onChange(of: env.session) { _, session in
            if session != nil && step == 1 { step = 2 }
        }
    }

    private func page<Content: View>(symbol: String, color: Color, title: String, message: String, @ViewBuilder actions: () -> Content) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(color)
                .frame(width: 128, height: 128)
                .background(color.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            actions()
            Spacer().frame(height: 56)
        }
        .padding(.horizontal, Spacing.xl)
    }

    private var welcome: some View {
        page(symbol: "circle.hexagongrid.fill", color: .recover, title: "Fuel. Train. Recover.",
             message: "HealthApp brings your food, training, sleep and body data together — so you can see how they affect each other.") {
            HStack(spacing: Spacing.m) {
                ForEach(Domain.allCases, id: \.self) { d in
                    Label(d.title, systemImage: d.symbol).font(.caption.weight(.semibold)).foregroundStyle(d.color)
                }
            }
            Button { step = env.session == nil ? 1 : 2 } label: { Text("Get started").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var signIn: some View {
        page(symbol: "person.crop.circle.badge.checkmark", color: .body, title: "Your private account",
             message: "Sign in with Apple — you can hide your email. Your data is encrypted and you can export or delete it anytime.") {
            if env.mode == .demo {
                Button { step = 2 } label: { Text("Continue with demo data").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Demo mode: no account needed; 90 days of sample data.").font(.caption).foregroundStyle(.secondary)
            } else if env.session != nil {
                Button { step = 2 } label: { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                SignInWithAppleCognitoButton()
            }
        }
    }

    @State private var healthRequested = false
    private var connectHealth: some View {
        page(symbol: "heart.text.square.fill", color: .train, title: "Connect Apple Health",
             message: "Read steps, energy, workouts, heart rate, HRV, sleep and body measurements; write the meals and weights you log here. You choose exactly which types.") {
            Button {
                Task {
                    try? await env.health.requestAuthorization(read: HealthMetricType.readTypes, write: HealthMetricType.writeTypes)
                    healthRequested = true
                    step = 3
                }
            } label: { Text(healthRequested ? "Connected" : "Connect Apple Health").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Not now") { step = 3 }
        }
    }

    @State private var ouraState: String?
    private var connectOura: some View {
        page(symbol: "circle.circle", color: .recover, title: "Connect Oura (optional)",
             message: "Add sleep, readiness, HRV and temperature from your Oura Ring. You can also pair a Bluetooth food scale later in Settings → Devices.") {
            Button {
                Task {
                    do { try await env.oura.connect(); ouraState = "Connected"; step = 4 }
                    catch { ouraState = error.localizedDescription }
                }
            } label: { Text("Connect Oura").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let ouraState { Text(ouraState).font(.caption).foregroundStyle(.secondary) }
            Button("Skip") { step = 4 }
        }
    }

    private var notifications: some View {
        page(symbol: "bell.badge.fill", color: .fuel, title: "Gentle reminders",
             message: "Meal reminders and recovery alerts help you keep logs complete. You can fine-tune every notification later.") {
            Button {
                Task {
                    if (try? await env.notifications.requestAuthorization()) == true {
                        await env.applyNotificationPrefs()
                        PushRegistration.register()
                    }
                    finish()
                }
            } label: { Text("Allow notifications").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Maybe later") { finish() }
        }
    }

    private func finish() {
        Haptics.success()
        env.hasOnboarded = true
        Task { await env.start() }
    }
}
