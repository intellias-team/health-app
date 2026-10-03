#if canImport(Network)
import Foundation
import Network

/// Wraps `NWPathMonitor`; calls `onReconnect` when the path transitions to `.satisfied`.
public final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "healthapp.connectivity")
    private var wasSatisfied = true
    private let lock = NSLock()
    public private(set) var isOnline = true

    public init() {}

    public func start(onReconnect: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.lock.lock()
            let reconnected = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            self.isOnline = satisfied
            self.lock.unlock()
            if reconnected { onReconnect() }
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}
#endif

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks

/// BGTaskScheduler identifiers (must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist).
public enum BackgroundSync {
    public static let refreshTaskID = "com.healthapp.ios.refresh"
    public static let processingTaskID = "com.healthapp.ios.sync-processing"

    /// Schedules the next app refresh (≥ 1 h). The task itself is handled by SwiftUI's
    /// `.backgroundTask(.appRefresh(BackgroundSync.refreshTaskID))` in the App scene.
    public static func scheduleAppRefresh(earliest: TimeInterval = 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Longer outbox drain / HealthKit backfill when on network (and ideally power).
    public static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
