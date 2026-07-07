//
//  TimeGrowApp.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI
import FirebaseCore

class AppDelegate: NSObject, UIApplicationDelegate {}

@main
struct TimeGrowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var taskService: TaskService
    @StateObject private var autoTrackingStore = AutoTrackingStore()
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
                .onAppear {
                    taskService.start()
                    autoTrackingStore.refreshMonitoring(for: taskService.tasks)
                    processPendingAutoTrackEvents()
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
