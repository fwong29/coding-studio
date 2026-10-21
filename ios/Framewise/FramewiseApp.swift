import SwiftUI

@main
struct FramewiseApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
