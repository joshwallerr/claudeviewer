import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// True when the system has the app registered to auto-launch on login.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// True when registration is even possible for this build. SMAppService
    /// requires the binary to be in /Applications or ~/Applications and
    /// running from a proper .app bundle. Bare `swift run` executables are
    /// rejected.
    static var isSupported: Bool {
        if #available(macOS 13.0, *) {
            return Bundle.main.bundleURL.pathExtension == "app"
        }
        return false
    }

    /// Returns nil on success, an error message otherwise.
    static func set(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return "Requires macOS 13+" }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
