import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let controller = HeadphonesController()

    private let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    private let touchMenuItem = NSMenuItem(title: "Touch Sensor: —", action: nil, keyEquivalent: "")
    private let reconnectMenuItem = NSMenuItem(title: "Reconnect", action: nil, keyEquivalent: "r")
    private let openLogMenuItem = NSMenuItem(title: "Open Log...", action: nil, keyEquivalent: "l")
    private let sendHexMenuItem = NSMenuItem(title: "Send Custom Hex...", action: nil, keyEquivalent: "h")
    private let probeMenuItem = NSMenuItem(title: "Probe Features", action: nil, keyEquivalent: "p")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusButton()
        configureMenu()
        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.render(state: state) }
        }
        controller.connect()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "SonyConnect") {
            button.image = image
        } else {
            button.title = "🎧"
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        touchMenuItem.target = self
        touchMenuItem.action = #selector(toggleTouchSensor)
        menu.addItem(touchMenuItem)

        menu.addItem(.separator())

        reconnectMenuItem.target = self
        reconnectMenuItem.action = #selector(reconnect)
        menu.addItem(reconnectMenuItem)

        openLogMenuItem.target = self
        openLogMenuItem.action = #selector(openLog)
        menu.addItem(openLogMenuItem)

        sendHexMenuItem.target = self
        sendHexMenuItem.action = #selector(sendCustomHex)
        menu.addItem(sendHexMenuItem)

        probeMenuItem.target = self
        probeMenuItem.action = #selector(probeFeatures)
        menu.addItem(probeMenuItem)

        menu.addItem(NSMenuItem(title: "Quit SonyConnect",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func render(state: HeadphonesController.State) {
        statusMenuItem.title = state.statusDescription
        switch state.touchSensorEnabled {
        case .some(true):
            touchMenuItem.title = "Touch Sensor: ON"
            touchMenuItem.state = .on
        case .some(false):
            touchMenuItem.title = "Touch Sensor: OFF"
            touchMenuItem.state = .off
        case .none:
            touchMenuItem.title = state.isConnected ? "Toggle Touch Sensor" : "Touch Sensor: —"
            touchMenuItem.state = .off
        }
        touchMenuItem.isEnabled = state.isConnected
    }

    @objc private func toggleTouchSensor() {
        controller.toggleTouchSensor()
    }

    @objc private func reconnect() {
        controller.connect()
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.url])
    }

    @objc private func probeFeatures() {
        controller.probeFeatures()
    }

    @objc private func sendCustomHex() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Send Custom Command Payload"
        alert.informativeText = "Hex bytes for the COMMAND_1 payload (e.g. \"F8 0C 01 01\"). Framing & checksum are added automatically."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "F8 0C 01 01"
        alert.accessoryView = input
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let bytes = parseHex(input.stringValue), !bytes.isEmpty else {
            let err = NSAlert()
            err.messageText = "Invalid hex"
            err.informativeText = "Expected pairs of hex digits separated by spaces or commas."
            err.runModal()
            return
        }
        controller.sendRawPayload(bytes)
    }

    private func parseHex(_ string: String) -> [UInt8]? {
        let cleaned = string
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: " ,;\t\n"))
            .joined()
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
