import UIKit
import MWDATCore

/// UIKit AppDelegate kept around purely to add a belt-and-suspenders URL
/// callback handler. SwiftUI's `.onOpenURL` is the primary path; this
/// catches the cases where the legacy UIApplication path is used by the
/// caller (some Meta AI versions appear to fall through to it).
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Catches the legacy custom-scheme path (datstreamios://...).
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        print("[AppDelegate] open url: \(url) options: \(options)")
        forwardToSDK(url)
        return true
    }

    /// Catches Universal Links (https://chrisc920.github.io/datstream-aasa/auth?...).
    /// Meta AI's modern flow uses Universal Links, so this is the primary path.
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            print("[AppDelegate] continueUserActivity: not a web URL: \(userActivity.activityType)")
            return false
        }
        print("[AppDelegate] continueUserActivity url: \(url)")
        forwardToSDK(url)
        return true
    }

    private func forwardToSDK(_ url: URL) {
        Task { @MainActor in
            do {
                let consumed = try await Wearables.shared.handleUrl(url)
                print("[AppDelegate] handleUrl consumed=\(consumed)")
            } catch {
                print("[AppDelegate] handleUrl threw: \(error)")
            }
        }
    }
}
