import CloudDiskKit
import GoogleSignIn
import SwiftUI

@main
struct CloudDiskApp: App {
    @StateObject private var core = AppCore()

    var body: some Scene {
        WindowGroup("CloudDisk") {
            ContentView(core: core)
                .task {
                    await core.prepare()
                }
                .onOpenURL { url in
                    // The OAuth redirect comes back through the custom scheme in Info.plist.
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
        .defaultSize(width: 940, height: 660)
    }
}
