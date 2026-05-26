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

private let log = Logger(subsystem: "com.tanat.sonyconnect", category: "bluetooth")

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

    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private(set) var status: Status = .disconnected {
        didSet {
            FileLogger.shared.log("bt", "status -> \(status)")
            onStatus?(status)
        }
    }

    private static let deviceNameHints = ["WH-1000XM4", "WH-1000XM5", "WH-1000XM3"]

    func connect() {
        if case .connected = status { return }
        status = .searching

        guard let raw = IOBluetoothDevice.pairedDevices() else {
            status = .failed(reason: "No paired Bluetooth devices found")
            return
        }
        let devices = raw.compactMap { $0 as? IOBluetoothDevice }
        FileLogger.shared.log("bt", "paired devices: \(devices.map { "\($0.name ?? "?")(\($0.addressString ?? "?"))" }.joined(separator: ", "))")
        guard let target = devices.first(where: { dev in
            let name = dev.name ?? ""
            return Self.deviceNameHints.contains { name.contains($0) }
        }) else {
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
        channel?.close()
        channel = nil
        device = nil
        status = .disconnected
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
        let uuid = IOBluetoothSDPUUID(bytes: sonyServiceUUIDBytes, length: sonyServiceUUIDBytes.count)
        guard let record = device.getServiceRecord(for: uuid) else {
            FileLogger.shared.log("bt", "Sony service UUID not found in cached SDP records")
            if let allRecords = device.services as? [IOBluetoothSDPServiceRecord] {
                for r in allRecords {
                    var ch: BluetoothRFCOMMChannelID = 0
                    let ok = r.getRFCOMMChannelID(&ch) == kIOReturnSuccess
                    FileLogger.shared.log("bt", "  service: \(r.getServiceName() ?? "?") rfcomm=\(ok ? String(ch) : "no")")
                }
            }
            return false
        }
        FileLogger.shared.log("bt", "Sony service found: \(record.getServiceName() ?? "?")")

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
            self.status = .failed(reason: "Sony service UUID not advertised by device")
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
