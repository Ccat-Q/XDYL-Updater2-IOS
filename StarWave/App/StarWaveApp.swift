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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
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

