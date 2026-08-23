import Foundation

final class HeadphonesController {
    enum NCMode: String {
        case noiseCancelling, ambient, off
    }

    struct EqPreset {
        let id: UInt8
        let name: String
    }

    struct State {
        var isConnected: Bool = false       // SPP control channel is open
        var deviceReachable: Bool = false   // headphones present at the BT (ACL) level
        var touchSensorEnabled: Bool? = nil
        var ncMode: NCMode? = nil
        var speakToChatEnabled: Bool? = nil
        var batteryLevel: Int? = nil
        var batteryCharging: Bool = false
        var eqPresets: [EqPreset] = []
        var eqCurrentPresetId: UInt8? = nil
        var eqBands: [Int] = []
        var autoOffOption: AutoPowerOffOption = .off
        var statusDescription: String = "Disconnected"
        var ambientLevel: Int = 20          // 0...20, meaningful only while ncMode == .ambient
        var ambientFocusOnVoice: Bool = false
        // Drives the few places the UI differs by generation (currently the
        // auto-power-off list, where only v2 can do "when taken off").
        var protocolIsV2: Bool = false
        var isWH1000XM6: Bool = false
    }

    private(set) var state = State() {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private let bluetooth = BluetoothClient()
    private let parser = SonyFrameParser()
    private let autoOff = AutoPowerOff()
    private let media = MediaController()
    private let policy: ConnectionPolicy
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
        static let batteryGet: UInt8 = 0x10
        static let batteryRet: UInt8 = 0x11
        static let batteryNotify: UInt8 = 0x13
        static let batterySingleInquiredType: UInt8 = 0x00   // BatteryInquiredType.BATTERY
        static let commonSetPowerOff: UInt8 = 0x22
        static let eqGetCapability: UInt8 = 0x50
        static let eqRetCapability: UInt8 = 0x51
        static let eqGetParam: UInt8 = 0x56
        static let eqRetParam: UInt8 = 0x57
        static let eqSetParam: UInt8 = 0x58
        static let eqNotifyParam: UInt8 = 0x59
        static let eqPresetInquiredType: UInt8 = 0x01        // EqEbbInquiredType.PRESET_EQ
        static let eqPresetCustom: UInt8 = 0xA0              // EqPresetId.CUSTOM
        static let eqPresetUnspecified: UInt8 = 0xFF         // EqPresetId.UNSPECIFIED
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

    // Second-generation opcodes (WH-CH720N, WH/WF-1000XM5, WF-1000XM4 — the
    // earbuds; the WH-1000XM4 headphones are v1).
    // The transport framing is identical to v1 — only these payload opcodes and
    // their byte layouts differ. Several values collide with v1 opcodes while
    // meaning something else entirely (0x22 is POWER_OFF on v1 but BATTERY_GET
    // on v2), so every send and every parse must be routed by protocol version.
    //
    // Layouts ported from SonyBridge (MIT, Copyright (c) 2020 Nir Harel,
    // Mor Gal, Sem Visscher, jimzrt, guilhermealbm and other contributors) —
    // https://github.com/AmitRajput-Dev/SonyBridge — which in turn credits
    // Gadgetbridge's SonyProtocolImplV2 and mos9527/SonyHeadphonesClient.
    private enum V2Opcode {
        static let initRequest: UInt8 = 0x00     // 00 00        -> RET 01 ...
        static let initReply: UInt8 = 0x01
        static let batteryGet: UInt8 = 0x22      // 22 00        -> RET 23 00 <level> <charging>
        static let batteryRet: UInt8 = 0x23
        static let batteryNotify: UInt8 = 0x25
        static let batterySingleInquiredType: UInt8 = 0x00
        static let ncasmGet: UInt8 = 0x66        // 66 <t>       -> RET 67 <t> 01 <effect> <type> <voice> <level>
        static let ncasmRet: UInt8 = 0x67
        static let ncasmSet: UInt8 = 0x68        // 68 <t> 01 <effect> <type> <voice> <level>
        static let ncasmNotify: UInt8 = 0x69
        // The NCASM inquired type differs within v2: most devices (CH720N,
        // WH/WF-1000XM5) take 0x15; only the ones Gadgetbridge marks with
        // AmbientSoundControl2 (WF-C700N/C710N/C510, ULT WEAR) take 0x17.
        // Replies may carry 0x15, 0x17 or 0x22 regardless.
        static let ncasmInquiredTypeBasic: UInt8 = 0x15
        static let ncasmInquiredTypeAsc2: UInt8 = 0x17
        static let ncasmReplyTypes: Set<UInt8> = [0x15, 0x17, 0x22]
        static let ncasmTypeNoiseCancelling: UInt8 = 0x00
        static let ncasmTypeAmbientSound: UInt8 = 0x01
        static let eqGet: UInt8 = 0x56           // 56 00        -> RET 57 00 <preset> 06 <6 bands>
        static let eqRet: UInt8 = 0x57
        static let eqSet: UInt8 = 0x58           // 58 00 <preset> 00  |  58 00 A0 06 <6 bands>
        static let eqNotify: UInt8 = 0x59
        static let eqInquiredType: UInt8 = 0x04
        // Power off exists on v2 too, just under its own opcode rather than
        // v1's 0x22 (which v2 reuses for BATTERY_GET).
        static let powerSet: UInt8 = 0x24        // 24 03 01
        static let powerInquiredType: UInt8 = 0x03
        static let powerOffValue: UInt8 = 0x01
        // General-setting family: same opcodes as v1 but the stored boolean is
        // inverted, and the touch panel lives in slot 0xD2.
        static let gsGet: UInt8 = 0xD6           // D6 D2        -> RET D7 D2 .. <inverted>
        static let gsRet: UInt8 = 0xD7
        static let gsSet: UInt8 = 0xD8           // D8 D2 00 <inverted>
        static let gsNotify: UInt8 = 0xD9
        // Touch-panel slot is discovered at runtime from GENERAL_SETTING_GET_CAPABILITY.
        // Auto power off runs on the device: send the setting once and the
        // headphones keep their own timer.
        static let apoGet: UInt8 = 0x26          // 26 05        -> RET 27 05 <c0> <c1>
        static let apoRet: UInt8 = 0x27
        static let apoSet: UInt8 = 0x28          // 28 05 <c0> <c1>
        static let apoNotify: UInt8 = 0x29       // 29 05 <c0> <c1>
        static let apoInquiredType: UInt8 = 0x05
        static let apoOff: (UInt8, UInt8) = (0x11, 0x00)

        // Two-byte code per timeout, in the order AutoPowerOffOption declares.
        static func apoCode(for option: AutoPowerOffOption) -> (UInt8, UInt8) {
            switch option {
            case .off: return apoOff
            case .fiveMinutes: return (0x00, 0x00)
            case .thirtyMinutes: return (0x01, 0x01)
            case .oneHour: return (0x02, 0x02)
            case .threeHours: return (0x03, 0x03)
            case .whenTakenOff: return (0x10, 0x00)
            }
        }

        static func apoOption(for code: (UInt8, UInt8)) -> AutoPowerOffOption? {
            AutoPowerOffOption.allCases.first { apoCode(for: $0) == code }
        }
        static let btnModeGet: UInt8 = 0xF6      // F6 <sub>     -> RET F7 <sub> ...
        static let btnModeRet: UInt8 = 0xF7
        static let btnModeSet: UInt8 = 0xF8      // F8 0C <0=on/1=off> 01
        static let btnModeNotify: UInt8 = 0xF9   // F9 0C <0=on/1=off> 01
        static let subSpeakToChat: UInt8 = 0x0C
    }

    private var protocolVersion: SonyProtocolVersion = .v1
    private var isV2: Bool { protocolVersion == .v2 }

    // Device families Gadgetbridge marks with AmbientSoundControl2 — the ones
    // whose NCASM payloads use inquired type 0x17 instead of 0x15.
    private static let asc2NameHints = ["WF-C700N", "WF-C710N", "WF-C510", "ULT WEAR"]
    private var ncasmInquiredTypeV2: UInt8 {
        Self.asc2NameHints.contains { deviceName.localizedCaseInsensitiveContains($0) }
            ? V2Opcode.ncasmInquiredTypeAsc2
            : V2Opcode.ncasmInquiredTypeBasic
    }

    private var touchPanelSlot: UInt8?
    private var touchPanelIsListType: Bool = false
    private var ncSettingType: UInt8 = 0x02  // device-reported; default DUAL_SINGLE_OFF for WH-1000XM4
    private var asmSettingType: UInt8 = 0x01 // device-reported; default LEVEL_ADJUSTMENT
    private var asmId: UInt8 = 0x00          // ambient mode: 0x00 NORMAL, 0x01 VOICE (Focus on Voice)
    private var currentAmbientLevel: UInt8 = HeadphonesController.maxAmbientLevel  // retained across NC-mode switches
    static let maxAmbientLevel: UInt8 = 20

    init() {
        policy = ConnectionPolicy()
        bluetooth.onStatus = { [weak self] s in self?.handleStatus(s) }
        bluetooth.onData = { [weak self] data in self?.handleIncoming(data) }
        autoOff.onShouldPowerOff = { [weak self] in self?.sendPowerOff() }
        autoOff.onOptionChanged = { [weak self] option in
            self?.state.autoOffOption = option
        }
        policy.onShouldConnect = { [weak self] in self?.bluetooth.connect() }
        policy.onShouldDisconnect = { [weak self] in
            guard let self = self else { return }
            // If a Mac-side auto-power-off countdown is armed, keep the SPP
            // channel open so it can actually reach the device when it fires —
            // otherwise the battery-saver disconnect kills the timer first.
            // v2 devices run the timeout themselves, so there is nothing to
            // keep alive for and the channel can close as usual.
            if self.autoOff.isEnabled && !self.isV2 {
                FileLogger.shared.log("policy", "idle disconnect skipped — auto-power-off armed")
                return
            }
            FileLogger.shared.log("policy", "releasing RFCOMM control channel")
            self.bluetooth.disconnect()
        }
        bluetooth.onReachabilityChange = { [weak self] reachable, name in
            self?.handleReachability(reachable, name: name)
        }
        state.autoOffOption = autoOff.option
        bluetooth.startReachabilityMonitoring()
        policy.start()
    }

    private func handleReachability(_ reachable: Bool, name: String?) {
        if let name = name { deviceName = name }
        state.deviceReachable = reachable
        // Keep the status line consistent with the icon while the SPP
        // channel is closed: "(idle)" when the device is still around,
        // "Disconnected" when it's gone.
        if !state.isConnected {
            state.statusDescription = reachable ? "\(deviceName) (idle)" : "Disconnected"
        }
    }

    var autoOffOption: AutoPowerOffOption {
        get { autoOff.option }
        set {
            policy.userActivity()
            autoOff.option = newValue
            // v2 keeps its own timer, so hand the setting over and let the
            // Mac-side countdown stay idle.
            if isV2 { sendAutoPowerOffV2(newValue) }
        }
    }

    private func sendAutoPowerOffV2(_ option: AutoPowerOffOption) {
        let code = V2Opcode.apoCode(for: option)
        sendPayload([V2Opcode.apoSet, V2Opcode.apoInquiredType, code.0, code.1],
                    label: "AUTO_POWER_OFF SET (v2)=\(option.title)")
    }

    private func parseAutoPowerOffV2(_ payload: [UInt8]) {
        // RET: 27 05 <c0> <c1>. Adopt whatever the device already has so a
        // timeout set from the phone app shows up here.
        guard payload.count >= 4, payload[1] == V2Opcode.apoInquiredType else { return }
        let code = (payload[2], payload[3])
        guard let option = V2Opcode.apoOption(for: code) else {
            FileLogger.shared.log("state",
                "AutoPowerOff v2 unknown code \(String(format: "%02X %02X", code.0, code.1))")
            return
        }
        autoOff.option = option
        FileLogger.shared.log("state", "AutoPowerOff v2 = \(option.title)")
    }

    func powerOff() {
        guard initialized else { return }
        sendPowerOff()
    }

    func connect() {
        // User clicked Reconnect — counts as user activity.
        policy.userActivity()
    }

    // Called when the menu is about to open. The policy treats this as
    // user activity: connects on demand if currently idle-disconnected
    // and pushes back the next idle-disconnect.
    func userActivity() {
        policy.userActivity()
    }

    func menuOpened() {
        policy.menuOpened()
    }

    func menuClosed() {
        policy.menuClosed()
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
        policy.userActivity()
        guard initialized else {
            FileLogger.shared.log("cmd", "toggle ignored: not initialized")
            return
        }
        let next = !(state.touchSensorEnabled ?? false)
        if isV2 {
            sendTouchSensorV2(enabled: next)
            state.touchSensorEnabled = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendTouchSensorGetV2()
            }
            return
        }
        sendTouchSensor(enabled: next)
        state.touchSensorEnabled = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendTouchSensorGet()
        }
    }

    func setNCMode(_ mode: NCMode) {
        policy.userActivity()
        guard initialized else { return }
        sendNcasmSet(mode: mode)
        state.ncMode = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendNcasmGet()
        }
    }

    func setAmbientLevel(_ level: Int) {
        policy.userActivity()
        guard initialized else { return }
        let clamped = UInt8(clamping: min(max(level, 0), Int(Self.maxAmbientLevel)))
        currentAmbientLevel = clamped
        state.ambientLevel = Int(clamped)
        guard state.ncMode == .ambient else { return }
        sendNcasmSet(mode: .ambient)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendNcasmGet()
        }
    }

    func setAmbientFocusOnVoice(_ enabled: Bool) {
        policy.userActivity()
        guard initialized else { return }
        asmId = enabled ? 0x01 : 0x00
        state.ambientFocusOnVoice = enabled
        guard state.ncMode == .ambient else { return }
        sendNcasmSet(mode: .ambient)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendNcasmGet()
        }
    }

    func toggleSpeakToChat() {
        policy.userActivity()
        guard initialized else { return }
        let next = !(state.speakToChatEnabled ?? false)
        sendSpeakToChat(enabled: next)
        state.speakToChatEnabled = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendSpeakToChatGet()
        }
    }

    func setEqPreset(_ id: UInt8) {
        policy.userActivity()
        guard initialized else { return }
        let setOpcode = isV2 ? V2Opcode.eqSet : Opcode.eqSetParam
        let inquiredType = isV2 ? V2Opcode.eqInquiredType : Opcode.eqPresetInquiredType
        sendPayload([setOpcode, inquiredType, id, 0x00],
                    label: "EQ SET preset=0x\(String(format: "%02X", id))")
        state.eqCurrentPresetId = id
        // Pull the resulting band curve for the new preset.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendEqGet()
        }
    }

    func setEqBands(_ bands: [Int]) {
        policy.userActivity()
        guard initialized, !bands.isEmpty else { return }
        // Custom band values must be sent under preset id UNSPECIFIED (0xFF),
        // not CUSTOM (0xA0). 0xA0 is a volatile preview the device drops on
        // the next SPP session; 0xFF makes it persist (this is what the Sony
        // app does — see nf/c.java j(EqPresetId, int[])).
        // v2 has no UNSPECIFIED preset — custom bands go out under CUSTOM (0xA0).
        var payload: [UInt8]
        if isV2 {
            // XM6/v2 exposes EQ as -6...+6 in the UI, but stores each band
            // as 0...12 on the wire, with raw 6 representing 0 dB.
            let encoded = bands.map { UInt8(clamping: min(max($0 + 6, 0), 12)) }
            payload = [V2Opcode.eqSet, V2Opcode.eqInquiredType,
                       state.eqCurrentPresetId == 0xA1 ? 0xA1 : Opcode.eqPresetCustom,
                       UInt8(encoded.count)]
            payload.append(contentsOf: encoded)
            sendPayload(payload, label: "EQ SET custom bands=\(bands) raw=\(encoded)")
        } else {
            payload = [Opcode.eqSetParam, Opcode.eqPresetInquiredType,
                       Opcode.eqPresetUnspecified, UInt8(bands.count)]
            payload.append(contentsOf: bands.map { UInt8(clamping: $0) })
            sendPayload(payload, label: "EQ SET custom bands=\(bands)")
        }

        if state.eqCurrentPresetId != 0xA1 {
            state.eqCurrentPresetId = Opcode.eqPresetCustom
        }
        state.eqBands = bands
    }

    // v2 keeps the general-setting opcodes but stores the flag inverted, and
    // the touch panel always sits in slot 0xD2 rather than being discovered.
    private func sendTouchSensorV2(enabled: Bool) {
        guard let slot = touchPanelSlot else {
            FileLogger.shared.log("cmd", "TouchSensor SET (v2) skipped: touch-panel slot not discovered")
            return
        }
        sendPayload([V2Opcode.gsSet, slot, 0x00, enabled ? 0x00 : 0x01],
                    label: "TouchSensor SET (v2)=\(enabled ? "ON" : "OFF") slot=\(String(format: "0x%02X", slot))")
    }

    private func sendTouchSensorGetV2() {
        guard let slot = touchPanelSlot else {
            FileLogger.shared.log("cmd", "TouchSensor GET (v2) skipped: touch-panel slot not discovered")
            return
        }
        sendPayload([V2Opcode.gsGet, slot],
                    label: "TouchSensor GET (v2) slot=\(String(format: "0x%02X", slot))")
    }

    private func parseTouchSensorV2(_ payload: [UInt8]) {
        guard payload.count >= 4,
              let slot = touchPanelSlot,
              payload[1] == slot else { return }
        let enabled = payload[payload.count - 1] == 0x00
        state.touchSensorEnabled = enabled
        FileLogger.shared.log("state", "TouchSensor v2 = \(enabled ? "ON" : "OFF")")
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
        if isV2 {
            sendPayload([V2Opcode.ncasmGet, ncasmInquiredTypeV2],
                        label: "NCASM GET (v2 t=0x\(String(format: "%02X", ncasmInquiredTypeV2)))")
            return
        }
        sendPayload([Opcode.ncasmGet, Opcode.ncasmCombinedInquiredType],
                    label: "NCASM GET")
    }

    // v2 layout: 68 17 01 <effect> <0=NC / 1=Ambient> <focusOnVoice> <level>
    private func sendNcasmSetV2(mode: NCMode) {
        let effect: UInt8 = (mode == .off) ? 0x00 : 0x01
        let type: UInt8 = (mode == .ambient) ? V2Opcode.ncasmTypeAmbientSound
                                             : V2Opcode.ncasmTypeNoiseCancelling
        // The device rejects level 0 while Ambient is selected, so clamp to 1.
        let level: UInt8 = (mode == .ambient) ? max(1, currentAmbientLevel) : 0
        sendPayload([V2Opcode.ncasmSet,
                     ncasmInquiredTypeV2,
                     0x01,
                     effect,
                     type,
                     asmId,
                     level],
                    label: "NCASM SET (v2)=\(mode.rawValue)")
    }

    private func sendNcasmSet(mode: NCMode) {
        if isV2 {
            sendNcasmSetV2(mode: mode)
            return
        }
        // Payload: 68 02 effect ncType ncValue asmType asmId asmLevel
        let effect: UInt8 = (mode == .off) ? 0x00 : 0x11   // OFF or ADJUSTMENT_COMPLETION
        let ncValue: UInt8 = (mode == .noiseCancelling) ? 0x02 : 0x00 // DUAL or OFF
        let asmLevel: UInt8 = (mode == .ambient) ? currentAmbientLevel : 0
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
        if isV2 {
            sendPayload([V2Opcode.btnModeGet, V2Opcode.subSpeakToChat],
                        label: "SpeakToChat GET (v2)")
            return
        }
        sendPayload([Opcode.systemGet, Opcode.smartTalkingMode],
                    label: "SpeakToChat GET")
    }

    private func sendSpeakToChat(enabled: Bool) {
        if isV2 {
            // v2 inverts the flag: 0x00 enables, 0x01 disables.
            sendPayload([V2Opcode.btnModeSet,
                         V2Opcode.subSpeakToChat,
                         enabled ? 0x00 : 0x01,
                         0x01],
                        label: "SpeakToChat SET (v2)=\(enabled ? "ON" : "OFF")")
            return
        }
        sendPayload([Opcode.systemSet,
                     Opcode.smartTalkingMode,
                     Opcode.smartTalkingParamModeOnOff,
                     enabled ? 0x01 : 0x00],
                    label: "SpeakToChat SET=\(enabled ? "ON" : "OFF")")
    }

    private func sendPowerOff() {
        // Pause first so audio doesn't briefly blast through the laptop
        // speakers when A2DP drops as the headphones power down.
        media.pause()
        // 0x22 means POWER_OFF on v1 but BATTERY_GET on v2, so v2 has its own
        // opcode rather than no power-off at all.
        if isV2 {
            sendPayload([V2Opcode.powerSet,
                         V2Opcode.powerInquiredType,
                         V2Opcode.powerOffValue],
                        label: "POWER_OFF (v2)")
            return
        }
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
        // Both generations open with the same two bytes; only v1 follows up
        // with the second handshake below.
        sendPayload([Opcode.initRequest, 0x00], label: "INIT_REQUEST")
        // Some firmware revisions need a second handshake before they
        // accept feature SETs. 0x06 ... is INIT_2_REQUEST (Gadgetbridge
        // PayloadTypeV1) and has no v2 equivalent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.awaitingInitResponse, !self.isV2 else { return }
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
        if isV2 {
            // v2 has no general-setting capability family (so no touch panel)
            // and no EQ capability query — the preset ids are fixed.
            state.eqPresets = Self.v2EqPresets
        } else {
            queryGeneralSettingCapabilities()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.sendNcasmGet()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            self?.sendSpeakToChatGet()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            self?.sendBatteryGet()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in
            guard let self = self, !self.isV2 else { return }
            self.sendEqCapabilityGet()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in
            self?.sendEqGet()
        }
        if isV2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.sendPayload([V2Opcode.apoGet, V2Opcode.apoInquiredType],
                                  label: "AUTO_POWER_OFF GET (v2)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { [weak self] in
                self?.queryGeneralSettingCapabilities()
            }
        } else {
            autoOff.arm(deviceName: deviceName)
        }
    }

    private func sendBatteryGet() {
        if isV2 {
            sendPayload([V2Opcode.batteryGet, V2Opcode.batterySingleInquiredType],
                        label: "BATTERY GET (v2)")
            return
        }
        sendPayload([Opcode.batteryGet, Opcode.batterySingleInquiredType],
                    label: "BATTERY GET")
    }

    private func sendEqCapabilityGet() {
        sendPayload([Opcode.eqGetCapability, Opcode.eqPresetInquiredType, 0x00],
                    label: "EQ GET_CAPABILITY")
    }

    private func sendEqGet() {
        if isV2 {
            sendPayload([V2Opcode.eqGet, V2Opcode.eqInquiredType], label: "EQ GET (v2)")
            return
        }
        sendPayload([Opcode.eqGetParam, Opcode.eqPresetInquiredType], label: "EQ GET")
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
            policy.setCurrentlyConnected(false)
            state.isConnected = false
            state.touchSensorEnabled = nil
            state.ncMode = nil
            state.speakToChatEnabled = nil
            state.batteryLevel = nil
            state.batteryCharging = false
            state.eqPresets = []
            state.eqCurrentPresetId = nil
            state.eqBands = []
            // Device may still be present (we just closed SPP for battery
            // saving) — reflect that instead of a flat "Disconnected".
            state.statusDescription = state.deviceReachable ? "\(deviceName) (idle)" : "Disconnected"
        case .searching, .connecting:
            // Transient. Don't overwrite the current statusDescription —
            // it lingers as "Disconnected" until we actually succeed.
            // This avoids the misleading "Connecting to WH-1000XM4…"
            // shown while IOBluetooth is timing out an unreachable
            // device.
            state.isConnected = false
            if case let .connecting(name) = status {
                deviceName = name
            }
        case .connected(let name):
            resetSessionState()
            deviceName = name
            // Provisional only: which service UUID answered is a hint, not the
            // answer. The generation is latched from the INIT reply's length
            // once it arrives (see latchProtocolVersion) — the init exchange
            // itself is identical across generations, so it is safe to send
            // before we know.
            protocolVersion = bluetooth.protocolVersion
            state.protocolIsV2 = isV2
            state.isWH1000XM6 = name.localizedCaseInsensitiveContains("WH-1000XM6")
            FileLogger.shared.log("state",
                "service UUID suggests \(isV2 ? "v2" : "v1"); awaiting INIT reply to confirm")
            policy.setCurrentlyConnected(true)
            state.isConnected = false
            state.deviceReachable = true
            state.statusDescription = "Initializing \(name)..."
            sendInit()
        case .failed:
            resetSessionState()
            autoOff.disarm()
            policy.setCurrentlyConnected(false)
            state.isConnected = false
            state.touchSensorEnabled = nil
            state.ncMode = nil
            state.speakToChatEnabled = nil
            state.batteryLevel = nil
            state.batteryCharging = false
            state.eqPresets = []
            state.eqCurrentPresetId = nil
            state.eqBands = []
            state.statusDescription = state.deviceReachable ? "\(deviceName) (idle)" : "Disconnected"
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

    // The generation is decided by the INIT reply's length, the same way
    // Gadgetbridge does it: v1 devices answer 4 payload bytes (WH-1000XM3/XM4:
    // 01 00 40/70 ..), v2 devices answer 8 (WF-1000XM4, WH/WF-1000XM5:
    // 01 00 0x 00 00 00 00 00). The service UUID only chose which SDP record
    // to open — a device advertising something unexpected still gets classified
    // by what it actually speaks.
    private func latchProtocolVersion(fromInitReplyLength count: Int) {
        let confirmed: SonyProtocolVersion = count >= 8 ? .v2 : .v1
        if confirmed != protocolVersion {
            FileLogger.shared.log("state",
                "INIT reply length \(count) contradicts service UUID hint — switching to \(confirmed)")
        }
        protocolVersion = confirmed
        state.protocolIsV2 = isV2
        FileLogger.shared.log("state", "protocol = \(isV2 ? "v2" : "v1") (INIT reply length \(count))")
    }

    private func interpret(_ packet: SonyPacket) {
        guard packet.dataType == .command1, let opcode = packet.payload.first else {
            return
        }
        // Canonical INIT_REPLY (0x01 ...) OR any state-dump packet that
        // arrives after we sent INIT_REQUEST both signal "device is ready".
        if awaitingInitResponse {
            if opcode == Opcode.initReply {
                latchProtocolVersion(fromInitReplyLength: packet.payload.count)
            }
            completeInit()
        }
        // Opcode values overlap between generations with different meanings, so
        // v2 replies must never fall through to the v1 table below.
        if isV2 {
            interpretV2(packet)
            return
        }
        switch opcode {
        case Opcode.gsRetCapability:
            parseGsCapability(packet.payload)
        case Opcode.batteryRet, Opcode.batteryNotify:
            parseBattery(packet.payload)
        case Opcode.eqRetCapability:
            parseEqCapability(packet.payload)
        case Opcode.eqRetParam, Opcode.eqNotifyParam:
            parseEqParam(packet.payload)
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

    // v2 devices don't answer an EQ capability query — the preset ids are fixed
    // in firmware and match the set v1 devices report.
    private static let v2EqPresets: [EqPreset] = [
        EqPreset(id: 0x00, name: "Off"),
        EqPreset(id: 0x30, name: "Heavy"),
        EqPreset(id: 0x31, name: "Clear"),
        EqPreset(id: 0x32, name: "Hard"),
        EqPreset(id: 0x33, name: "Soft"),
        EqPreset(id: Opcode.eqPresetCustom, name: "Custom 1"),
        EqPreset(id: 0xA1, name: "Custom 2"),
    ]

    private func interpretV2(_ packet: SonyPacket) {
        guard let opcode = packet.payload.first else { return }
        switch opcode {
        case V2Opcode.ncasmRet, V2Opcode.ncasmNotify:
            parseNcasmV2(packet.payload)
        case V2Opcode.batteryRet, V2Opcode.batteryNotify:
            parseBatteryV2(packet.payload)
        case V2Opcode.eqRet, V2Opcode.eqNotify:
            parseEqParamV2(packet.payload)
        case V2Opcode.btnModeRet, V2Opcode.btnModeNotify:
            parseBtnModeV2(packet.payload)
        case V2Opcode.apoRet, V2Opcode.apoNotify:
            parseAutoPowerOffV2(packet.payload)
        case Opcode.gsRetCapability:
            parseGsCapabilityV2(packet.payload)
        case V2Opcode.gsRet, V2Opcode.gsNotify:
            parseTouchSensorV2(packet.payload)
        case V2Opcode.initReply:
            break
        default:
            FileLogger.shared.log("state",
                "v2 unhandled opcode 0x\(String(format: "%02X", opcode))")
        }
    }

    private func parseGsCapabilityV2(_ payload: [UInt8]) {
        guard payload.count >= 5 else { return }

        let slot = payload[1]
        let nameLen = Int(payload[4])
        guard payload.count >= 5 + nameLen else { return }

        let nameBytes = Array(payload[5..<(5 + nameLen)])
        let name = String(bytes: nameBytes, encoding: .ascii) ?? "<bad>"

        FileLogger.shared.log(
            "state",
            "GS v2 slot=\(String(format: "0x%02X", slot)) name='\(name)'"
        )

        if name == "TOUCH_PANEL_SETTING" {
            touchPanelSlot = slot
            FileLogger.shared.log(
                "state",
                "→ Touch panel v2 discovered at slot \(String(format: "0x%02X", slot))"
            )
            sendTouchSensorGetV2()
        }
    }

    private func parseNcasmV2(_ payload: [UInt8]) {
        // RET / NOTIFY: 67 17 01 <effect> <0=NC / 1=Ambient> <focusOnVoice> <level>
        guard payload.count >= 7, V2Opcode.ncasmReplyTypes.contains(payload[1]) else { return }
        let on = payload[3] != 0
        let ambient = payload[4] != 0
        let voice = payload[5] != 0
        let level = payload[6]

        let mode: NCMode
        if !on {
            mode = .off
        } else if ambient {
            mode = .ambient
        } else {
            mode = .noiseCancelling
        }
        if ambient, level > 0 { currentAmbientLevel = level }
        asmId = voice ? 0x01 : 0x00
        state.ncMode = mode
        state.ambientLevel = Int(currentAmbientLevel)
        state.ambientFocusOnVoice = voice
        FileLogger.shared.log("state",
            "NCASM v2 = \(mode.rawValue) (on=\(on) ambient=\(ambient) voice=\(voice) level=\(level))")
    }

    private func parseBatteryV2(_ payload: [UInt8]) {
        // RET / NOTIFY: 23 <type> <level 0-100> <charging 0/1>
        guard payload.count >= 4,
              payload[1] == V2Opcode.batterySingleInquiredType else { return }
        let level = Int(payload[2])
        guard (0...100).contains(level) else { return }
        state.batteryLevel = level
        state.batteryCharging = payload[3] == 0x01
        FileLogger.shared.log("state",
            "Battery v2 = \(level)% charging=\(state.batteryCharging)")
    }

    private func parseEqParamV2(_ payload: [UInt8]) {
        // RET: 57 00 <preset> <bandCount> <bands...>  (same shape as v1, with
        // inquiredType 0x00 instead of 0x01)
        guard payload.count >= 4,
              payload[1] == V2Opcode.eqInquiredType else { return }
        let preset = payload[2]
        let count = Int(payload[3])
        guard payload.count >= 4 + count else { return }
        let rawBands = payload[4..<(4 + count)].map { Int($0) }
        let bands = rawBands.map { $0 - 6 }
        state.eqCurrentPresetId = preset
        state.eqBands = bands
        FileLogger.shared.log("state",
            "EQ v2 current=0x\(String(format: "%02X", preset)) bands=\(bands) raw=\(rawBands)")
    }

    private func parseBtnModeV2(_ payload: [UInt8]) {
        // RET: F7 <sub> <value...>. For Speak-to-Chat the value byte mirrors
        // the SET encoding, where 0x00 means enabled. Inferred from the SET
        // layout — unverified against hardware.
        guard payload.count >= 3, payload[1] == V2Opcode.subSpeakToChat else { return }
        let enabled = payload[2] == 0x00
        state.speakToChatEnabled = enabled
        FileLogger.shared.log("state", "SpeakToChat v2 = \(enabled ? "ON" : "OFF")")
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
        // Device reports 0 while NC/Off is active — only overwrite our
        // remembered level when it reports an actual ambient level, so
        // switching back to Ambient later restores the last level instead
        // of resetting to 0.
        if asmLevel > 0 { currentAmbientLevel = asmLevel }

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
        state.ambientLevel = Int(currentAmbientLevel)
        state.ambientFocusOnVoice = (asmId == 0x01)
        FileLogger.shared.log("state",
            "NCASM = \(mode.rawValue) (effect=\(String(format: "0x%02X", effect)) ncT=\(ncSettingType) ncV=\(ncValue) asmT=\(asmSettingType) asmL=\(asmLevel))")
    }

    private func parseBattery(_ payload: [UInt8]) {
        // RET / NOTIFY for single-battery devices:
        // [0]=opcode 0x11/0x13, [1]=BatteryInquiredType (0=BATTERY),
        // [2]=level (0..100), [3]=charging status (0 no, 1 yes, F0 unknown)
        guard payload.count >= 4,
              payload[1] == Opcode.batterySingleInquiredType else { return }
        let level = Int(payload[2])
        let charging = payload[3] == 0x01
        state.batteryLevel = level
        state.batteryCharging = charging
        FileLogger.shared.log("state", "Battery = \(level)% charging=\(charging)")
    }

    private func parseEqCapability(_ payload: [UInt8]) {
        // [0]=0x51 [1]=inquiredType [2]=bandCount [3]=levelSteps
        // [4]=presetCount, then per preset: [presetId][nameLen][name…]
        guard payload.count >= 5, payload[1] == Opcode.eqPresetInquiredType else { return }
        let presetCount = Int(payload[4])
        var presets: [EqPreset] = []
        var i = 5
        for _ in 0..<presetCount {
            guard i + 1 < payload.count else { break }
            let id = payload[i]
            let nameLen = Int(payload[i + 1])
            let nameStart = i + 2
            let nameEnd = nameStart + nameLen
            guard nameEnd <= payload.count else { break }
            let capName = nameLen > 0
                ? String(bytes: payload[nameStart..<nameEnd], encoding: .utf8)
                : nil
            let name = (capName?.isEmpty == false) ? capName! : Self.fallbackPresetName(id)
            presets.append(EqPreset(id: id, name: name))
            i = nameEnd
        }
        // Drop the USER_SETTING1…5 slots (0xA1–0xA5) — not useful here.
        presets.removeAll { $0.id >= 0xA1 && $0.id <= 0xA5 }
        // Move the manually-editable "Custom" preset to the very end of
        // the list — it's the one the band sliders write to.
        if let idx = presets.firstIndex(where: { $0.id == Opcode.eqPresetCustom }) {
            presets.append(presets.remove(at: idx))
        }
        state.eqPresets = presets
        FileLogger.shared.log("state", "EQ presets: \(presets.map { "\($0.name)=0x\(String(format: "%02X", $0.id))" }.joined(separator: ", "))")
    }

    private func parseEqParam(_ payload: [UInt8]) {
        // [0]=0x57/0x59 [1]=inquiredType [2]=presetId [3]=nBands [4…]=band values
        guard payload.count >= 4, payload[1] == Opcode.eqPresetInquiredType else { return }
        let presetId = payload[2]
        let nBands = Int(payload[3])
        var bands: [Int] = []
        if 4 + nBands <= payload.count {
            bands = payload[4..<(4 + nBands)].map { Int($0) }
        }
        state.eqCurrentPresetId = presetId
        state.eqBands = bands
        FileLogger.shared.log("state", "EQ current=0x\(String(format: "%02X", presetId)) bands=\(bands)")
    }

    static func fallbackPresetName(_ id: UInt8) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x01: return "Rock"
        case 0x02: return "Pop"
        case 0x03: return "Jazz"
        case 0x04: return "Dance"
        case 0x05: return "EDM"
        case 0x06: return "R&B / Hip-Hop"
        case 0x07: return "Acoustic"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case 0xA0: return "Custom"
        case 0xA1: return "User 1"
        case 0xA2: return "User 2"
        case 0xA3: return "User 3"
        case 0xA4: return "User 4"
        case 0xA5: return "User 5"
        default: return String(format: "Preset 0x%02X", id)
        }
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
