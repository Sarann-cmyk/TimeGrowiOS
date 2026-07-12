//
//  TimeGrowApp.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI
import FirebaseCore
import UIKit

/// Handles regular (non-ActivityKit) remote notifications: registers this device for silent
/// background-wake pushes and runs the supplied handler when one arrives. Push-to-start alone
/// proved unreliable on-device (ActivityKit acknowledges the push but doesn't always materialize
/// the activity); a `content-available` push wakes the app so it can call the already-proven
/// local `LiveActivityManager.reconcile()` path instead.
class AppDelegate: NSObject, UIApplicationDelegate {
    var remoteNotificationTokenHandler: ((String) -> Void)?
    var backgroundNotificationHandler: ((@escaping () -> Void) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        remoteNotificationTokenHandler?(hexToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagnosticsLog.log("push", "Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let handler = backgroundNotificationHandler else {
            completionHandler(.noData)
            return
        }
        handler { completionHandler(.newData) }
    }
}

@main
struct TimeGrowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var taskService: TaskService
    @StateObject private var autoTrackingStore = AutoTrackingStore()
    @StateObject private var accentColorManager = AccentColorManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        _taskService = StateObject(wrappedValue: TaskService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(taskService)
                .environmentObject(autoTrackingStore)
                .environmentObject(accentColorManager)
                .onAppear {
                    taskService.start()
                    autoTrackingStore.refreshMonitoring(for: taskService.tasks)
                    processPendingAutoTrackEvents()
                    LiveActivityManager.shared.pushTokenHandler = { taskID, token in
                        taskService.updateLiveActivityPushToken(taskID: taskID, token: token)
                    }
                    delegate.remoteNotificationTokenHandler = { token in
                        taskService.updateAPNsDeviceToken(token)
                    }
                    delegate.backgroundNotificationHandler = { done in
                        taskService.fetchTasksOnce { tasks in
                            LiveActivityManager.shared.reconcile(tasks: tasks)
                            done()
                        }
                    }
                }
                .task {
                    for await token in LiveActivityManager.shared.pushToStartTokenUpdates {
                        taskService.updateActivityPushToStartToken(token)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    taskService.handleScenePhase(newPhase)
                    if newPhase == .active {
                        autoTrackingStore.refreshAuthorizationStatus()
                        autoTrackingStore.refreshMonitoring(for: taskService.tasks)
                        processPendingAutoTrackEvents()
                    }
                }
                .onChange(of: taskService.tasks) { _, tasks in
                    autoTrackingStore.refreshMonitoring(for: tasks)
                }
        }
    }

    private func processPendingAutoTrackEvents() {
        let events = autoTrackingStore.drainPendingEvents()
        taskService.processPendingAutoTrackEvents(events)
    }
}
