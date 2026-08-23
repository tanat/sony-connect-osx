import AppKit
import ServiceManagement

enum LaunchAtLoginResult {
    case changed(Bool)
    case unsupported
    case failed(Error)
}

final class LaunchAtLoginManager {
    var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginResult {
        guard #available(macOS 13.0, *) else { return .unsupported }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .changed(isEnabled)
        } catch {
            return .failed(error)
        }
    }
}
