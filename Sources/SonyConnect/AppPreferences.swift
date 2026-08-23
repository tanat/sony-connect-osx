import Foundation

/// Preferences owned by the app shell rather than by the headphone protocol.
final class AppPreferences {
    static let shared = AppPreferences()

    private enum Key {
        static let hideIconWhenDisconnected = "HideIconWhenDisconnected"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hideIconWhenDisconnected: Bool {
        get { defaults.bool(forKey: Key.hideIconWhenDisconnected) }
        set { defaults.set(newValue, forKey: Key.hideIconWhenDisconnected) }
    }
}
