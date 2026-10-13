import SwiftUI
import UIKit

final class StarWaveAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.handleBackgroundEvents(completionHandler: completionHandler)
    }
}

@main
struct StarWaveApp: App {
    @UIApplicationDelegateAdaptor(StarWaveAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("developer.continuousSampling") private var continuousSampling = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
                .task(id: "\(scenePhase == .active)-\(model.isAuthenticated)") {
                    if scenePhase == .active && model.isAuthenticated { await model.monitorNotifications() }
                }
                .onAppear { if continuousSampling { PerformanceMonitor.shared.start(continuous: true) } }
                .onChange(of: continuousSampling) { enabled in
                    if enabled { PerformanceMonitor.shared.start(continuous: true) }
                    else { PerformanceMonitor.shared.stop() }
                }
                .alert("提示", isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )) {
                    Button("好", role: .cancel) { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
    }
}
