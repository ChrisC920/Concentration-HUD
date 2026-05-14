import SwiftUI
import MWDATCore

@main
struct DATStreamiOSApp: App {
    /// UIApplicationDelegateAdaptor wires up the legacy UIKit URL handler
    /// as a backstop for SwiftUI's `.onOpenURL`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned at the App level so the registration callback URL is handled
    /// the same way regardless of navigation state inside ContentView.
    @State private var dat = DATSessionController()

    init() {
        // Trigger iOS Bluetooth permission prompt early, before the DAT SDK
        // tries to use CBCentralManager (which silently fails with "API MISUSE:
        // ... not powered on" if permission hasn't been requested yet).
        BluetoothPrimer.shared.prime()
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables.configure() failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(dat: dat)
                .onOpenURL { url in
                    print("[App] onOpenURL: \(url)")
                    Task { await dat.handleUrl(url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        print("[App] onContinueUserActivity: \(url)")
                        Task { await dat.handleUrl(url) }
                    }
                }
        }
    }
}
