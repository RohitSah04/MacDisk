import CloudDiskKit
import GoogleSignIn
import SwiftUI

@main
struct CloudDiskApp: App {
    @StateObject private var core = AppCore()

    var body: some Scene {
        WindowGroup("CloudDisk") {
            RootView(core: core)
                .task {
                    await core.prepare()
                }
                .onOpenURL { url in
                    // The OAuth redirect comes back through the custom scheme in Info.plist.
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
        .defaultSize(width: 1080, height: 700)
    }
}
