import SwiftUI

@main
struct CaesuraIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We manage all windows manually — no default SwiftUI scene
        Settings {
            EmptyView()
        }
    }
}
