import Foundation

// Keeps Sony's SPP/RFCOMM control channel open only while the user is
// actively interacting with SonyConnect.
//
// A2DP audio playback does not require this channel, and holding it open
// unnecessarily prevents Sony's phone app from taking the control session.
//
// Connect trigger:
//   - user opens the SonyConnect menu
//   - user explicitly clicks Reconnect
//
// Disconnect trigger:
//   - no SonyConnect user activity for a short grace period
final class ConnectionPolicy {
    static let idleThreshold: TimeInterval = 10
    static let pollInterval: TimeInterval = 2

    var onShouldConnect: (() -> Void)?
    var onShouldDisconnect: (() -> Void)?

    private var timer: Timer?
    private var lastActiveDate = Date()
    private var currentlyConnected = false
    private var menuIsOpen = false

    func start() {
        guard timer == nil else { return }

        lastActiveDate = Date()

        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }

        timer = t
        RunLoop.main.add(t, forMode: .common)

        FileLogger.shared.log(
            "policy",
            "started; on-demand RFCOMM, idle threshold=\(Int(Self.idleThreshold))s"
        )
    }

    func setCurrentlyConnected(_ connected: Bool) {
        currentlyConnected = connected

        if connected {
            lastActiveDate = Date()
        }
    }

    // Opening the menu or explicitly reconnecting counts as control activity.
    func userActivity() {
        lastActiveDate = Date()

        if !currentlyConnected {
            FileLogger.shared.log("policy", "user activity → request connect")
            onShouldConnect?()
        }
    }

    func menuOpened() {
        menuIsOpen = true
        lastActiveDate = Date()
        FileLogger.shared.log("policy", "menu opened")

        if !currentlyConnected {
            FileLogger.shared.log("policy", "menu open → request connect")
            onShouldConnect?()
        }
    }

    func menuClosed() {
        menuIsOpen = false
        lastActiveDate = Date()
        FileLogger.shared.log(
            "policy",
            "menu closed; release grace=\(Int(Self.idleThreshold))s"
        )
    }

    private func tick() {
        guard currentlyConnected, !menuIsOpen else { return }

        let idle = Date().timeIntervalSince(lastActiveDate)

        if idle >= Self.idleThreshold {
            FileLogger.shared.log(
                "policy",
                "control idle \(Int(idle))s → request disconnect"
            )
            onShouldDisconnect?()
        }
    }
}
