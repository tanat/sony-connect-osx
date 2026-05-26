import CoreAudio
import Foundation

// Monitors macOS audio output for "headphones idle" and asks the
// controller to power off the device after a fixed idle threshold.
// Idle = the AudioDeviceID whose name matches the headphones is not
// in the "running somewhere" state (no process is feeding it audio).
final class AutoPowerOff {
    static let defaultsKey = "AutoOffEnabled"
    static let thresholdSeconds: TimeInterval = 30 * 60
    static let pollInterval: TimeInterval = 60

    var onShouldPowerOff: (() -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            onEnabledChanged?(newValue)
            if newValue, isArmed {
                start()
            } else {
                stop()
            }
        }
    }

    private var deviceNameMatch: String = ""
    private var isArmed: Bool = false  // headphones connected + ready
    private var timer: Timer?
    private var lastActiveDate = Date()

    func arm(deviceName: String) {
        deviceNameMatch = deviceName
        isArmed = true
        lastActiveDate = Date()
        if isEnabled {
            start()
        }
    }

    func disarm() {
        isArmed = false
        stop()
    }

    private func start() {
        stop()
        lastActiveDate = Date()
        FileLogger.shared.log("autoOff", "armed; threshold=\(Int(Self.thresholdSeconds))s, poll=\(Int(Self.pollInterval))s")
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isArmed, isEnabled else { return }
        let running = isAudioActive()
        if running {
            lastActiveDate = Date()
        } else {
            let idle = Date().timeIntervalSince(lastActiveDate)
            if idle >= Self.thresholdSeconds {
                FileLogger.shared.log("autoOff", "idle \(Int(idle))s exceeds threshold, requesting power-off")
                lastActiveDate = Date()  // avoid retriggering before disconnect
                onShouldPowerOff?()
            }
        }
    }

    private func isAudioActive() -> Bool {
        guard !deviceNameMatch.isEmpty else { return false }
        for id in audioDeviceIDs() {
            guard let name = audioDeviceName(id),
                  name.localizedCaseInsensitiveContains(deviceNameMatch) else { continue }
            if audioDeviceRunning(id) {
                return true
            }
        }
        return false
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private func audioDeviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func audioDeviceRunning(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
