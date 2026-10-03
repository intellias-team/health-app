import SwiftUI
import UIKit
import SyncKit
import NotificationsKit
import CoreModels

@main
struct HealthAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment.bootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task {
                    appDelegate.env = env
                    await env.start()
                }
                .onOpenURL { env.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await env.syncNow() }
            case .background:
                BackgroundSync.scheduleAppRefresh()
            default:
                break
            }
        }
        // BGAppRefreshTask (identifier listed in Info.plist BGTaskSchedulerPermittedIdentifiers).
        .backgroundTask(.appRefresh(BackgroundSync.refreshTaskID)) {
            BackgroundSync.scheduleAppRefresh()
            await env.performBackgroundRefresh()
        }
    }
}

/// Root: onboarding until the user has signed in and connected sources, then the tab UI.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if env.session == nil || !env.hasOnboarded {
                OnboardingView()
            } else {
                RootTabView()
            }
        }
        .tint(.recover)
    }
}

/// Push registration callbacks (APNs token → `POST /v1/devices`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor var env: AppEnvironment?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = NotificationCopy.hexToken(deviceToken)
        Task { @MainActor in await env?.registerDevice(apnsToken: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Push is optional; local reminders still work.
    }
}
