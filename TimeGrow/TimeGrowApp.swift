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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        _taskService = StateObject(wrappedValue: TaskService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(taskService)
                .onAppear {
                    taskService.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    taskService.handleScenePhase(newPhase)
                }
        }
    }
}
