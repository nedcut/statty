import Foundation
import ServiceManagement

/// Launch at login via the system's Login Items (System Settings > General > Login Items).
@MainActor
enum LoginItem {
    private static let setUpKey = "didSetUpLoginItem"

    /// Only an installed .app can be a login item, not `swift run`.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Statty: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// Turn launch at login on the first time the app runs; after that, respect the user's toggle.
    static func enableOnFirstLaunch() {
        guard isAvailable, !UserDefaults.standard.bool(forKey: setUpKey) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: setUpKey)
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
