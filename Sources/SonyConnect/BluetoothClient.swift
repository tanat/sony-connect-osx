import Foundation
import IOBluetooth
import OSLog

// Sony's proprietary RFCOMM service UUID used by WH-1000XM4 and related models.
private let sonyServiceUUIDBytes: [UInt8] = [
    0x96, 0xCC, 0x20, 0x3E,
    0x50, 0x68,
    0x46, 0xAD,
    0xB3, 0x2D,
    0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA,
]

// Second-generation service UUID (WH-CH720N, WH/WF-1000XM5, recent XM4 units).
// Devices advertise either this or the v1 UUID above — never both — and the
// payload opcodes differ per generation even though the framing is identical.
private let sonyServiceUUIDV2Bytes: [UInt8] = [
    0x95, 0x6C, 0x7B, 0x26,
    0xD4, 0x9A,
    0x4B, 0xA8,
    0xB0, 0x3F,
    0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2,
]

private let log = Logger(subsystem: "com.tanat.sonyconnect", category: "bluetooth")

// Which generation of Sony's MDR protocol the connected device speaks. Set
// during service discovery from whichever service UUID the device advertises.
enum SonyProtocolVersion {
    case v1
    case v2
}

final class BluetoothClient: NSObject {
    enum Status {
        case disconnected
        case searching
        case connecting(deviceName: String)
        case connected(deviceName: String)
        case failed(reason: String)
    }

    var onStatus: ((Status) -> Void)?
    var onData: ((Data) -> Void)?
    // Fires when the headphones' baseband (ACL) link to the Mac comes or
    // goes — independent of whether our SPP control channel is open.
    // Passes (reachable, deviceName?).
    var onReachabilityChange: ((Bool, String?) -> Void)?

    // Valid once status reaches .connected; reflects which service UUID opened
    // the channel. Callers use it to pick the matching opcode set.
    private(set) var protocolVersion: SonyProtocolVersion = .v1

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var reconnectTimer: Timer?
    private var suppressAutoReconnect = false
    private var lastSuccessfulDeviceAddress: String?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private static let reconnectInterval: TimeInterval = 5
    private(set) var status: Status = .disconnected {
        didSet {
            FileLogger.shared.log("bt", "status -> \(status)")
            onStatus?(status)
            switch status {
            case .connected:
                cancelReconnect()
            case .failed:
                scheduleReconnect()
            case .disconnected:
                if !suppressAutoReconnect {
                    scheduleReconnect()
                }
            case .searching, .connecting:
                break
            }
        }
    }

    // Begin watching the paired headphones' baseband connection so the UI
    // can reflect "device present" vs. "device off/out of range" even while
    // our SPP channel is intentionally closed for battery saving.
    func startReachabilityMonitoring() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(aclDeviceConnected(_:device:))
        )
        if let target = targetPairedDevice(), target.isConnected() {
            registerDisconnect(for: target)
            onReachabilityChange?(true, target.name)
        } else {
            onReachabilityChange?(false, nil)
        }
    }

    func isTargetDeviceConnected() -> Bool {
        targetPairedDevice()?.isConnected() ?? false
    }

    private func targetPairedDevice() -> IOBluetoothDevice? {
        guard let raw = IOBluetoothDevice.pairedDevices() else { return nil }

        let devices = raw
            .compactMap { $0 as? IOBluetoothDevice }
            .filter { isTargetDevice($0) }

        if let connected = devices.first(where: { $0.isConnected() }) {
            return connected
        }

        if let address = lastSuccessfulDeviceAddress,
           let lastUsed = devices.first(where: { $0.addressString == address }) {
            return lastUsed
        }

        return devices.first
    }

    private func isTargetDevice(_ device: IOBluetoothDevice) -> Bool {
        let name = device.name ?? ""
        return SupportedDevices.nameHints.contains { name.contains($0) }
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(aclDeviceDisconnected(_:device:))
        )
    }

    @objc private func aclDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isTargetDevice(device) else { return }
        FileLogger.shared.log("bt", "ACL connected: \(device.name ?? "?")")
        registerDisconnect(for: device)
        onReachabilityChange?(true, device.name)
    }

    @objc private func aclDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard isTargetDevice(device) else { return }
        FileLogger.shared.log("bt", "ACL disconnected: \(device.name ?? "?")")
        onReachabilityChange?(false, device.name)
    }

    func setAutoReconnectEnabled(_ enabled: Bool) {
        suppressAutoReconnect = !enabled

        if !enabled {
            cancelReconnect()
        }

        FileLogger.shared.log(
            "bt",
            "automatic RFCOMM reconnect \(enabled ? "enabled" : "disabled")"
        )
    }

    func connect() {
        suppressAutoReconnect = false
        cancelReconnect()
        if case .connected = status { return }
        if case .connecting = status { return }
        status = .searching

        guard let target = targetPairedDevice() else {
            status = .failed(reason: "Sony WH-1000XM4 not paired")
            return
        }

        device = target
        let name = target.name ?? target.addressString ?? "Sony headphones"
        status = .connecting(deviceName: name)

        if findServiceAndOpen(device: target) { return }

        log.info("Service record not cached; performing SDP query")
        if target.performSDPQuery(self) != kIOReturnSuccess {
            status = .failed(reason: "SDP query failed to start")
        }
    }

    func disconnect() {
        suppressAutoReconnect = true
        cancelReconnect()
        channel?.close()
        channel = nil
        device = nil
        status = .disconnected
    }

    private func scheduleReconnect() {
        guard reconnectTimer == nil else { return }
        let t = Timer(timeInterval: Self.reconnectInterval, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil
            self?.attemptReconnect()
        }
        reconnectTimer = t
        RunLoop.main.add(t, forMode: .common)
        FileLogger.shared.log("bt", "reconnect scheduled in \(Int(Self.reconnectInterval))s")
    }

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptReconnect() {
        switch status {
        case .connected, .connecting, .searching:
            return
        case .disconnected, .failed:
            FileLogger.shared.log("bt", "reconnect attempt")
            connect()
        }
    }

    func send(_ data: Data) {
        guard let channel = channel else {
            FileLogger.shared.log("bt", "send: NO CHANNEL")
            return
        }
        FileLogger.shared.hex("tx", data)
        var bytes = [UInt8](data)
        let result = bytes.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnNoMemory }
            return channel.writeSync(base, length: UInt16(buffer.count))
        }
        if result != kIOReturnSuccess {
            FileLogger.shared.log("bt", "writeSync failed: \(result)")
        }
    }

    @discardableResult
    private func findServiceAndOpen(device: IOBluetoothDevice) -> Bool {
        // Try the original UUID first, then the second-generation one. A device
        // advertises exactly one of them, and that choice determines which
        // opcode set the rest of the session must use.
        let candidates: [(SonyProtocolVersion, [UInt8])] = [
            (.v1, sonyServiceUUIDBytes),
            (.v2, sonyServiceUUIDV2Bytes),
        ]

        var found: (version: SonyProtocolVersion, record: IOBluetoothSDPServiceRecord)?
        for (version, bytes) in candidates {
            let uuid = IOBluetoothSDPUUID(bytes: bytes, length: bytes.count)
            if let record = device.getServiceRecord(for: uuid) {
                found = (version, record)
                break
            }
        }

        guard let (version, record) = found else {
            FileLogger.shared.log("bt", "Neither v1 nor v2 Sony service UUID found in cached SDP records")
            if let allRecords = device.services as? [IOBluetoothSDPServiceRecord] {
                for r in allRecords {
                    var ch: BluetoothRFCOMMChannelID = 0
                    let ok = r.getRFCOMMChannelID(&ch) == kIOReturnSuccess
                    FileLogger.shared.log("bt", "  service: \(r.getServiceName() ?? "?") rfcomm=\(ok ? String(ch) : "no")")
                }
            }
            return false
        }

        protocolVersion = version
        FileLogger.shared.log("bt", "Sony service found: \(record.getServiceName() ?? "?") protocol=\(version)")

        var channelID: BluetoothRFCOMMChannelID = 0
        let getResult = record.getRFCOMMChannelID(&channelID)
        guard getResult == kIOReturnSuccess else {
            status = .failed(reason: "Service record has no RFCOMM channel")
            return false
        }
        FileLogger.shared.log("bt", "RFCOMM channel id = \(channelID)")

        var openedChannel: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelAsync(&openedChannel,
                                                       withChannelID: channelID,
                                                       delegate: self)
        guard openResult == kIOReturnSuccess else {
            status = .failed(reason: "openRFCOMMChannelAsync error: \(openResult)")
            return false
        }
        channel = openedChannel
        return true
    }
}

extension BluetoothClient {
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard status == kIOReturnSuccess, let device = device else {
            self.status = .failed(reason: "SDP query failed: \(status)")
            return
        }
        if !findServiceAndOpen(device: device) {
            self.status = .failed(reason: "No Sony control service (v1 or v2) advertised by device")
        }
    }
}

extension BluetoothClient: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error != kIOReturnSuccess {
            status = .failed(reason: "RFCOMM open failed: \(error)")
            channel = nil
            return
        }
        if let connectedDevice = rfcommChannel.getDevice() {
            lastSuccessfulDeviceAddress = connectedDevice.addressString
        }
        let name = rfcommChannel.getDevice()?.name ?? "Sony headphones"
        status = .connected(deviceName: name)
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        let data = Data(bytes: dataPointer, count: dataLength)
        FileLogger.shared.hex("rx", data)
        onData?(data)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channel = nil
        status = .disconnected
    }
}
