import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case today, food, activity, recovery, body, trends, coach

    var title: String {
        switch self {
        case .today: return "Today"
        case .food: return "Food"
        case .activity: return "Activity"
        case .recovery: return "Recovery"
        case .body: return "Body"
        case .trends: return "Trends"
        case .coach: return "Coach"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max.fill"
        case .food: return "fork.knife"
        case .activity: return "figure.run"
        case .recovery: return "moon.zzz.fill"
        case .body: return "figure.stand"
        case .trends: return "chart.xyaxis.line"
        case .coach: return "bubble.left.and.text.bubble.right.fill"
        }
    }
}

/// All seven product tabs. On iOS 18+ uses the `Tab` API with `.sidebarAdaptable` (tab bar on iPhone with the
/// system "More" overflow, sidebar on iPad); on iOS 17 a classic `TabView` (system "More" overflow on iPhone).
/// Calendar and Settings live in the Today toolbar.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        if #available(iOS 18.0, *) {
            TabView(selection: $env.selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                        content(for: tab)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: $env.selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    content(for: tab)
                        .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                        .tag(tab)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .food: FoodLogView()
        case .activity: ActivityView()
        case .recovery: RecoveryView()
        case .body: BodyView()
        case .trends: TrendsHomeView()
        case .coach: CoachView()
        }
    }
}
