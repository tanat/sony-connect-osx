import Foundation

final class HeadphonesController {
    struct State {
        var isConnected: Bool = false
        var touchSensorEnabled: Bool? = nil
        var statusDescription: String = "Disconnected"
    }

    private(set) var state = State() {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private let bluetooth = BluetoothClient()
    private let parser = SonyFrameParser()
    private var outgoingSequence: UInt8 = 0
    private var initialized = false
    private var awaitingInitResponse = false
    private var deviceName: String = "headphones"

    // Sony MDR V1 opcodes (from JADX decompile of Sony Headphones Connect
    // 9.3.0, package com.sony.songpal.tandemfamily.message.mdr.v1.table1).
    // 0xD0..0xD9 = GENERAL_SETTING_* family.
    // Inside GENERAL_SETTING_* payloads, second byte is the "GsInquiredType"
    // = slot identifier: D1 = GS1, D2 = GS2, D3 = GS3.
    // Sony stores TOUCH_PANEL_SETTING in one of these slots, chosen per-firmware.
    private enum Opcode {
        static let initRequest: UInt8 = 0x00
        static let initReply: UInt8 = 0x01
        static let gsGetCapability: UInt8 = 0xD0
        static let gsRetCapability: UInt8 = 0xD1
        static let touchSensorGet: UInt8 = 0xD6
        static let touchSensorRet: UInt8 = 0xD7
        static let touchSensorSet: UInt8 = 0xD8
        static let touchSensorNotify: UInt8 = 0xD9
        static let gs1SubId: UInt8 = 0xD1
        static let gs2SubId: UInt8 = 0xD2
        static let gs3SubId: UInt8 = 0xD3
    }

    private var touchPanelSlot: UInt8?    // discovered from capability response
    private var touchPanelIsListType: Bool = false  // BOOLEAN_TYPE vs LIST_TYPE

    init() {
        bluetooth.onStatus = { [weak self] s in self?.handleStatus(s) }
        bluetooth.onData = { [weak self] data in self?.handleIncoming(data) }
    }

    func connect() {
        initialized = false
        awaitingInitResponse = false
        outgoingSequence = 0
        parser.reset()
        bluetooth.connect()
    }

    func toggleTouchSensor() {
        guard initialized else {
            FileLogger.shared.log("cmd", "toggle ignored: not initialized")
            return
        }
        let next = !(state.touchSensorEnabled ?? false)
        sendTouchSensor(enabled: next)
        state.touchSensorEnabled = next
        // Verify the actual post-SET state — some firmware versions
        // silently ignore SET and the only ground-truth is a fresh GET.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendTouchSensorGet()
        }
    }

    func sendRawPayload(_ payload: [UInt8]) {
        sendPayload(payload, label: "raw")
    }

    private func sendTouchSensor(enabled: Bool) {
        let slot = touchPanelSlot ?? Opcode.gs1SubId  // best guess if not yet discovered
        let settingType: UInt8 = touchPanelIsListType ? 0x02 : 0x01
        sendPayload([Opcode.touchSensorSet, slot, settingType,
                     enabled ? 0x01 : 0x00],
                    label: "TouchSensor SET=\(enabled ? "ON" : "OFF") slot=\(String(format: "0x%02X", slot)) type=\(settingType == 2 ? "LIST" : "BOOL")")
    }

    private func sendTouchSensorGet() {
        let slot = touchPanelSlot ?? Opcode.gs1SubId
        sendPayload([Opcode.touchSensorGet, slot],
                    label: "TouchSensor GET slot=\(String(format: "0x%02X", slot))")
    }

    private func queryGeneralSettingCapabilities() {
        let slots: [UInt8] = [Opcode.gs1SubId, Opcode.gs2SubId, Opcode.gs3SubId]
        for (i, slot) in slots.enumerated() {
            let delay = 0.3 + Double(i) * 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendPayload([Opcode.gsGetCapability, slot, 0x00],
                                  label: "GS GET_CAPABILITY slot=\(String(format: "0x%02X", slot))")
            }
        }
    }

    private func sendInit() {
        awaitingInitResponse = true
        sendPayload([Opcode.initRequest, 0x00], label: "INIT_REQUEST")
        // Some firmware revisions need a second handshake before they
        // accept feature SETs. 0x06 ... is INIT_2_REQUEST (Gadgetbridge
        // PayloadTypeV1).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.sendPayload([0x06, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00],
                              label: "INIT_2_REQUEST")
        }
        // Fallback: complete init even if no canonical INIT_REPLY arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.initialized else { return }
            FileLogger.shared.log("state", "INIT timeout — completing anyway")
            self.completeInit()
        }
    }

    private func completeInit() {
        guard !initialized else { return }
        initialized = true
        awaitingInitResponse = false
        state.isConnected = true
        state.statusDescription = "Connected: \(deviceName)"
        FileLogger.shared.log("state", "INIT complete, discovering general-setting slots")
        queryGeneralSettingCapabilities()
    }

    private func sendPayload(_ payload: [UInt8], label: String) {
        let packet = SonyPacket(dataType: .command1,
                                sequence: outgoingSequence,
                                payload: payload)
        outgoingSequence ^= 1
        let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        FileLogger.shared.log("cmd", "\(label) payload=[\(hex)]")
        bluetooth.send(SonyFraming.encode(packet))
    }

    private func handleStatus(_ status: BluetoothClient.Status) {
        switch status {
        case .disconnected:
            initialized = false
            state.isConnected = false
            state.touchSensorEnabled = nil
            state.statusDescription = "Disconnected"
        case .searching:
            state.isConnected = false
            state.statusDescription = "Searching..."
        case .connecting(let name):
            deviceName = name
            state.isConnected = false
            state.statusDescription = "Connecting to \(name)..."
        case .connected(let name):
            deviceName = name
            state.isConnected = false
            state.statusDescription = "Initializing \(name)..."
            sendInit()
        case .failed(let reason):
            initialized = false
            state.isConnected = false
            state.statusDescription = "Error: \(reason)"
        }
    }

    private func handleIncoming(_ data: Data) {
        let packets = parser.feed(data)
        for packet in packets {
            let hex = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            FileLogger.shared.log("packet", "RX type=0x\(String(format: "%02X", packet.dataType.rawValue)) seq=\(packet.sequence) payload=[\(hex)]")
            if packet.dataType != .ack {
                let ack = SonyPacket(dataType: .ack,
                                     sequence: packet.sequence ^ 1,
                                     payload: [])
                bluetooth.send(SonyFraming.encode(ack))
            }
            interpret(packet)
        }
    }

    private func interpret(_ packet: SonyPacket) {
        guard packet.dataType == .command1, let opcode = packet.payload.first else {
            return
        }
        // Canonical V1 INIT_REPLY (0x01 ...) OR any state-dump packet that
        // arrives after we sent INIT_REQUEST both signal "device is ready".
        if awaitingInitResponse {
            completeInit()
        }
        switch opcode {
        case Opcode.gsRetCapability:
            parseGsCapability(packet.payload)
        case Opcode.touchSensorRet:
            if packet.payload.count >= 4 {
                let slot = packet.payload[1]
                let type = packet.payload[2]
                let raw = packet.payload[3]
                FileLogger.shared.log("state", "GS RET slot=\(String(format: "0x%02X", slot)) type=\(type) value=\(String(format: "0x%02X", raw))")
                if slot == (touchPanelSlot ?? 0xFF) {
                    let enabled = raw != 0
                    state.touchSensorEnabled = enabled
                    FileLogger.shared.log("state", "TouchSensor RET = \(enabled ? "ON" : "OFF")")
                }
            }
        case Opcode.touchSensorNotify:
            if packet.payload.count >= 4 {
                let slot = packet.payload[1]
                let raw = packet.payload[3]
                FileLogger.shared.log("state", "GS NTFY slot=\(String(format: "0x%02X", slot)) value=\(String(format: "0x%02X", raw))")
            }
        default:
            break
        }
    }

    private func parseGsCapability(_ payload: [UInt8]) {
        // Format: [D1][slot][stringFormat][nameLen][name...][descLen][desc...][gsSettingType][listData?]
        guard payload.count >= 5 else {
            FileLogger.shared.log("state", "GS RET_CAPABILITY too short")
            return
        }
        let slot = payload[1]
        let nameFormat = payload[2]
        let nameLen = Int(payload[3])
        guard payload.count >= 4 + nameLen + 1 else { return }
        let nameBytes = Array(payload[4..<(4 + nameLen)])
        let name = String(bytes: nameBytes, encoding: .ascii) ?? "<bad>"

        let descLenIdx = 4 + nameLen
        let descLen = Int(payload[descLenIdx])
        let descEnd = descLenIdx + 1 + descLen
        guard payload.count > descEnd else { return }
        let settingType = payload[descEnd]
        let typeName = settingType == 1 ? "BOOLEAN" : settingType == 2 ? "LIST" : "?"

        FileLogger.shared.log("state",
            "GS slot=\(String(format: "0x%02X", slot)) name='\(name)' nameFormat=\(nameFormat) settingType=\(typeName)")

        // ENUM_NAME (format=2) + name="TOUCH_PANEL_SETTING" identifies the slot.
        if nameFormat == 0x02 && name == "TOUCH_PANEL_SETTING" {
            touchPanelSlot = slot
            touchPanelIsListType = (settingType == 2)
            FileLogger.shared.log("state",
                "→ Touch panel discovered at slot \(String(format: "0x%02X", slot)), type=\(typeName)")
            // Now that we know the slot, query the current state.
            sendTouchSensorGet()
        }
    }

    func probeFeatures() {
        let getCommands: [UInt8] = [
            0x11, 0x13, 0x21, 0x39, 0x51, 0x71, 0x81,
            0xA1, 0xC1, 0xD1, 0xE1, 0xF3, 0xF5,
        ]
        let subIds: [UInt8] = [0x00, 0x01, 0x02, 0x05, 0x80]
        var probes: [[UInt8]] = []
        for cmd in getCommands {
            for sub in subIds {
                probes.append([cmd, sub])
            }
        }
        FileLogger.shared.log("probe", "=== starting sweep (\(probes.count) probes) ===")
        for (i, payload) in probes.enumerated() {
            let delay = Double(i) * 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                FileLogger.shared.log("probe", ">>> [\(hex)]")
                self?.sendRawPayload(payload)
            }
        }
        let endDelay = Double(probes.count) * 0.3 + 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + endDelay) {
            FileLogger.shared.log("probe", "=== sweep complete ===")
        }
    }
}
