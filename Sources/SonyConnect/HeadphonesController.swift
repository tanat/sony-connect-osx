import Foundation

final class HeadphonesController {
    enum NCMode: String {
        case noiseCancelling, ambient, off
    }

    struct State {
        var isConnected: Bool = false
        var touchSensorEnabled: Bool? = nil
        var ncMode: NCMode? = nil
        var speakToChatEnabled: Bool? = nil
        var autoOffEnabled: Bool = false
        var statusDescription: String = "Disconnected"
    }

    private(set) var state = State() {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private let bluetooth = BluetoothClient()
    private let parser = SonyFrameParser()
    private let autoOff = AutoPowerOff()
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
        static let commonSetPowerOff: UInt8 = 0x22
        static let powerOffFixedValue: UInt8 = 0x00
        static let powerOffUserOff: UInt8 = 0x01
        static let ncasmGet: UInt8 = 0x66
        static let ncasmRet: UInt8 = 0x67
        static let ncasmSet: UInt8 = 0x68
        static let ncasmNotify: UInt8 = 0x69
        static let ncasmCombinedInquiredType: UInt8 = 0x02   // NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE
        static let gsGetCapability: UInt8 = 0xD0
        static let gsRetCapability: UInt8 = 0xD1
        static let touchSensorGet: UInt8 = 0xD6
        static let touchSensorRet: UInt8 = 0xD7
        static let touchSensorSet: UInt8 = 0xD8
        static let touchSensorNotify: UInt8 = 0xD9
        static let gs1SubId: UInt8 = 0xD1
        static let gs2SubId: UInt8 = 0xD2
        static let gs3SubId: UInt8 = 0xD3
        static let systemGet: UInt8 = 0xF6
        static let systemRet: UInt8 = 0xF7
        static let systemSet: UInt8 = 0xF8
        static let systemNotify: UInt8 = 0xF9
        static let smartTalkingMode: UInt8 = 0x05            // SystemInquiredType.SMART_TALKING_MODE
        static let smartTalkingParamModeOnOff: UInt8 = 0x01
    }

    private var touchPanelSlot: UInt8?
    private var touchPanelIsListType: Bool = false
    private var ncSettingType: UInt8 = 0x02  // device-reported; default DUAL_SINGLE_OFF for WH-1000XM4
    private var asmSettingType: UInt8 = 0x01 // device-reported; default LEVEL_ADJUSTMENT
    private var asmId: UInt8 = 0x00          // NORMAL ambient mode
    private static let maxAsmLevel: UInt8 = 20

    init() {
        bluetooth.onStatus = { [weak self] s in self?.handleStatus(s) }
        bluetooth.onData = { [weak self] data in self?.handleIncoming(data) }
        autoOff.onShouldPowerOff = { [weak self] in self?.sendPowerOff() }
        autoOff.onEnabledChanged = { [weak self] _ in
            guard let self = self else { return }
            self.state.autoOffEnabled = self.autoOff.isEnabled
        }
        state.autoOffEnabled = autoOff.isEnabled
    }

    var autoOffEnabled: Bool {
        get { autoOff.isEnabled }
        set { autoOff.isEnabled = newValue }
    }

    func powerOff() {
        guard initialized else { return }
        sendPowerOff()
    }

    func connect() {
        bluetooth.connect()
    }

    private func resetSessionState() {
        initialized = false
        awaitingInitResponse = false
        outgoingSequence = 0
        parser.reset()
        touchPanelSlot = nil
        touchPanelIsListType = false
        ncSettingType = 0x02
        asmSettingType = 0x01
        asmId = 0x00
    }

    func toggleTouchSensor() {
        guard initialized else {
            FileLogger.shared.log("cmd", "toggle ignored: not initialized")
            return
        }
        let next = !(state.touchSensorEnabled ?? false)
        sendTouchSensor(enabled: next)
        state.touchSensorEnabled = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendTouchSensorGet()
        }
    }

    func setNCMode(_ mode: NCMode) {
        guard initialized else { return }
        sendNcasmSet(mode: mode)
        state.ncMode = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendNcasmGet()
        }
    }

    func toggleSpeakToChat() {
        guard initialized else { return }
        let next = !(state.speakToChatEnabled ?? false)
        sendSpeakToChat(enabled: next)
        state.speakToChatEnabled = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendSpeakToChatGet()
        }
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

    private func sendNcasmGet() {
        sendPayload([Opcode.ncasmGet, Opcode.ncasmCombinedInquiredType],
                    label: "NCASM GET")
    }

    private func sendNcasmSet(mode: NCMode) {
        // Payload: 68 02 effect ncType ncValue asmType asmId asmLevel
        let effect: UInt8 = (mode == .off) ? 0x00 : 0x11   // OFF or ADJUSTMENT_COMPLETION
        let ncValue: UInt8 = (mode == .noiseCancelling) ? 0x02 : 0x00 // DUAL or OFF
        let asmLevel: UInt8 = (mode == .ambient) ? Self.maxAsmLevel : 0
        let payload: [UInt8] = [
            Opcode.ncasmSet,
            Opcode.ncasmCombinedInquiredType,
            effect,
            ncSettingType,
            ncValue,
            asmSettingType,
            asmId,
            asmLevel,
        ]
        sendPayload(payload, label: "NCASM SET=\(mode.rawValue)")
    }

    private func sendSpeakToChatGet() {
        sendPayload([Opcode.systemGet, Opcode.smartTalkingMode],
                    label: "SpeakToChat GET")
    }

    private func sendSpeakToChat(enabled: Bool) {
        sendPayload([Opcode.systemSet,
                     Opcode.smartTalkingMode,
                     Opcode.smartTalkingParamModeOnOff,
                     enabled ? 0x01 : 0x00],
                    label: "SpeakToChat SET=\(enabled ? "ON" : "OFF")")
    }

    private func sendPowerOff() {
        sendPayload([Opcode.commonSetPowerOff,
                     Opcode.powerOffFixedValue,
                     Opcode.powerOffUserOff],
                    label: "POWER_OFF")
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
            guard let self = self, self.awaitingInitResponse else { return }
            self.sendPayload([0x06, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00],
                             label: "INIT_2_REQUEST")
        }
        // Fallback: complete init even if no canonical INIT_REPLY arrives.
        // The awaitingInitResponse check makes the timeout a no-op if
        // the session was reset (disconnect/failure) before it fired.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self,
                  self.awaitingInitResponse,
                  !self.initialized else { return }
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
        FileLogger.shared.log("state", "INIT complete, discovering features")
        queryGeneralSettingCapabilities()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.sendNcasmGet()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            self?.sendSpeakToChatGet()
        }
        autoOff.arm(deviceName: deviceName)
    }

    private func sendPayload(_ payload: [UInt8], label: String) {
        // Suppress sends if the BT layer has dropped — avoids a flood of
        // "NO CHANNEL" lines after a mid-init disconnect.
        guard case .connected = bluetooth.status else {
            FileLogger.shared.log("cmd", "skip \(label): not connected")
            return
        }
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
            resetSessionState()
            autoOff.disarm()
            state.isConnected = false
            state.touchSensorEnabled = nil
            state.ncMode = nil
            state.speakToChatEnabled = nil
            state.statusDescription = "Disconnected"
        case .searching:
            state.isConnected = false
            state.statusDescription = "Searching..."
        case .connecting(let name):
            deviceName = name
            state.isConnected = false
            state.statusDescription = "Connecting to \(name)..."
        case .connected(let name):
            resetSessionState()  // start every new session from a clean slate
            deviceName = name
            state.isConnected = false
            state.statusDescription = "Initializing \(name)..."
            sendInit()
        case .failed(let reason):
            resetSessionState()
            autoOff.disarm()
            state.isConnected = false
            state.touchSensorEnabled = nil
            state.ncMode = nil
            state.speakToChatEnabled = nil
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
        case Opcode.ncasmRet, Opcode.ncasmNotify:
            parseNcasm(packet.payload)
        case Opcode.systemRet, Opcode.systemNotify:
            parseSystem(packet.payload)
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

    private func parseNcasm(_ payload: [UInt8]) {
        // RET / NOTIFY format for inquiredType=0x02 NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE:
        // [0]=opcode 0x67/0x69, [1]=inquiredType, [2]=effect, [3]=ncSettingType,
        // [4]=ncValue/dualSingle, [5]=asmSettingType, [6]=asmId, [7]=asmLevel
        guard payload.count >= 8,
              payload[1] == Opcode.ncasmCombinedInquiredType else { return }
        let effect = payload[2]
        ncSettingType = payload[3]
        let ncValue = payload[4]
        asmSettingType = payload[5]
        asmId = payload[6]
        let asmLevel = payload[7]

        let mode: NCMode
        if effect == 0x00 {
            mode = .off
        } else if ncValue != 0x00 {
            mode = .noiseCancelling
        } else if asmLevel > 0 {
            mode = .ambient
        } else {
            mode = .off
        }
        state.ncMode = mode
        FileLogger.shared.log("state",
            "NCASM = \(mode.rawValue) (effect=\(String(format: "0x%02X", effect)) ncT=\(ncSettingType) ncV=\(ncValue) asmT=\(asmSettingType) asmL=\(asmLevel))")
    }

    private func parseSystem(_ payload: [UInt8]) {
        // SystemInquiredType is at [1]. Payload structure after that
        // depends on whether this is RET or NTFY:
        //   RET (0xF7): [SmartTalkingModeSettingType=0x00 ON_OFF] [value]
        //   NTFY (0xF9): [SmartTalkingModeParameterType=0x01 MODE_ON_OFF] [value]
        // We accept both — middle byte logged for diagnostics, value at [3].
        guard payload.count >= 4,
              payload[1] == Opcode.smartTalkingMode else { return }
        let middle = payload[2]
        let raw = payload[3]
        let enabled = raw != 0
        state.speakToChatEnabled = enabled
        FileLogger.shared.log("state",
            "SpeakToChat = \(enabled ? "ON" : "OFF") (mid=\(String(format: "0x%02X", middle)))")
    }
}
