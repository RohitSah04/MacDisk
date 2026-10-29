
import SwiftUI
import GoogleSignIn
import FileProvider

@main
struct MyApp: App {
    @State private var registrationMessage = "Preparing CloudDisk..."

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await registerCloudDiskDomain()
                }
        }
    }

    @MainActor
    private func registerCloudDiskDomain() async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                rawValue: "primary-google-drive"
            ),
            displayName: "CloudDisk"
        )

        do {
            try await NSFileProviderManager.add(domain)

            registrationMessage = "CloudDisk location registered."
            print(registrationMessage)

            do {
                guard let manager = NSFileProviderManager(for: domain) else {
                    print("CloudDisk: Could not create File Provider manager.")
                    return
                }

                try await manager.signalEnumerator(for: .rootContainer)
                print("CloudDisk: Requested Finder root refresh.")
                print("CloudDisk: Requested Finder root refresh.")
            } catch {
                print("CloudDisk: Root refresh failed: \(error)")
            }
        } catch {
            let nsError = error as NSError

            // A domain with this identifier may already exist.
            if nsError.domain == NSCocoaErrorDomain &&
                nsError.code == NSFileWriteFileExistsError {
                registrationMessage = "CloudDisk location already exists."
                print(registrationMessage)
            } else {
                registrationMessage =
                    "Could not register CloudDisk: \(error.localizedDescription)"
                print(registrationMessage)
            }
        }
    }
}
