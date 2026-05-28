import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller = HeadphonesController()
    private let popupMenu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    private let batteryMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let touchMenuItem = NSMenuItem(title: "Touch Sensor: —", action: nil, keyEquivalent: "")
    private let ncParentMenuItem = NSMenuItem(title: "Noise Cancelling: —", action: nil, keyEquivalent: "")
    private let ncOnItem = NSMenuItem(title: "Noise Cancelling", action: nil, keyEquivalent: "")
    private let ncAmbientItem = NSMenuItem(title: "Ambient Sound", action: nil, keyEquivalent: "")
    private let ncOffItem = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
    private let speakToChatMenuItem = NSMenuItem(title: "Speak-to-Chat: —", action: nil, keyEquivalent: "")
    private let autoOffMenuItem = NSMenuItem(title: "Power Off after 30 min idle", action: nil, keyEquivalent: "")
    private let powerOffMenuItem = NSMenuItem(title: "Power Off Headphones", action: nil, keyEquivalent: "")
    private let reconnectMenuItem = NSMenuItem(title: "Reconnect", action: nil, keyEquivalent: "r")
    private let openLogMenuItem = NSMenuItem(title: "Open Log…", action: nil, keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusButton()
        configureMenu()
        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.render(state: state) }
        }
        render(state: controller.state)
        controller.connect()
    }

    // MARK: - Icon

    private func applyIcon() {
        guard let image = NSImage(systemSymbolName: "airpodsmax",
                                  accessibilityDescription: "SonyConnect") else {
            statusItem.button?.title = "🎧"
            return
        }
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    // MARK: - Setup

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
    }

    private func configureMenu() {
        popupMenu.delegate = self

        statusMenuItem.isEnabled = false
        popupMenu.addItem(statusMenuItem)

        batteryMenuItem.isEnabled = false
        batteryMenuItem.isHidden = true
        popupMenu.addItem(batteryMenuItem)

        popupMenu.addItem(.separator())

        touchMenuItem.target = self
        touchMenuItem.action = #selector(toggleTouchSensor)
        popupMenu.addItem(touchMenuItem)

        // Noise Cancelling submenu (three radio-style options)
        let ncSubmenu = NSMenu(title: "Noise Cancelling")
        for (item, tag) in [(ncOnItem, 0), (ncAmbientItem, 1), (ncOffItem, 2)] {
            item.target = self
            item.action = #selector(setNCFromMenu(_:))
            item.tag = tag
            ncSubmenu.addItem(item)
        }
        ncParentMenuItem.submenu = ncSubmenu
        popupMenu.addItem(ncParentMenuItem)

        speakToChatMenuItem.target = self
        speakToChatMenuItem.action = #selector(toggleSpeakToChat)
        popupMenu.addItem(speakToChatMenuItem)

        popupMenu.addItem(.separator())

        autoOffMenuItem.target = self
        autoOffMenuItem.action = #selector(toggleAutoOff)
        popupMenu.addItem(autoOffMenuItem)

        powerOffMenuItem.target = self
        powerOffMenuItem.action = #selector(powerOff)
        popupMenu.addItem(powerOffMenuItem)

        popupMenu.addItem(.separator())

        reconnectMenuItem.target = self
        reconnectMenuItem.action = #selector(reconnect)
        popupMenu.addItem(reconnectMenuItem)

        openLogMenuItem.target = self
        openLogMenuItem.action = #selector(openLog)
        popupMenu.addItem(openLogMenuItem)

        popupMenu.addItem(.separator())
        popupMenu.addItem(NSMenuItem(title: "Quit SonyConnect",
                                     action: #selector(NSApplication.terminate(_:)),
                                     keyEquivalent: "q"))
    }

    // MARK: - Click routing

    @objc private func handleClick(_ sender: Any?) {
        showMenu()
    }

    private func showMenu() {
        statusItem.menu = popupMenu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach the menu so the next click is routed through our action
        // handler again (otherwise NSStatusItem auto-shows the menu on
        // every click).
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - State → UI

    private func render(state: HeadphonesController.State) {
        statusMenuItem.title = state.statusDescription
        autoOffMenuItem.state = state.autoOffEnabled ? .on : .off

        if let level = state.batteryLevel {
            let suffix = state.batteryCharging ? " (charging)" : ""
            batteryMenuItem.title = "Battery: \(level)%\(suffix)"
            batteryMenuItem.isHidden = false
        } else {
            batteryMenuItem.isHidden = true
        }

        if !state.isConnected {
            touchMenuItem.title = "Touch Sensor: —"
            touchMenuItem.state = .off
            touchMenuItem.isEnabled = false
            ncParentMenuItem.title = "Noise Cancelling: —"
            ncParentMenuItem.isEnabled = false
            speakToChatMenuItem.title = "Speak-to-Chat: —"
            speakToChatMenuItem.state = .off
            speakToChatMenuItem.isEnabled = false
            powerOffMenuItem.isEnabled = false
            return
        }
        powerOffMenuItem.isEnabled = true

        // Touch sensor row
        switch state.touchSensorEnabled {
        case .some(true):
            touchMenuItem.title = "Touch Sensor: ON"
            touchMenuItem.state = .on
            touchMenuItem.isEnabled = true
        case .some(false):
            touchMenuItem.title = "Touch Sensor: OFF"
            touchMenuItem.state = .off
            touchMenuItem.isEnabled = true
        case .none:
            touchMenuItem.title = "Touch Sensor: …"
            touchMenuItem.state = .off
            touchMenuItem.isEnabled = false
        }

        // Noise Cancelling submenu
        ncParentMenuItem.isEnabled = true
        let ncLabel: String
        switch state.ncMode {
        case .some(.noiseCancelling): ncLabel = "ON"
        case .some(.ambient): ncLabel = "Ambient"
        case .some(.off): ncLabel = "Off"
        case .none: ncLabel = "…"
        }
        ncParentMenuItem.title = "Noise Cancelling: \(ncLabel)"
        ncOnItem.state = state.ncMode == .noiseCancelling ? .on : .off
        ncAmbientItem.state = state.ncMode == .ambient ? .on : .off
        ncOffItem.state = state.ncMode == .off ? .on : .off

        // Speak-to-Chat
        speakToChatMenuItem.isEnabled = state.speakToChatEnabled != nil
        switch state.speakToChatEnabled {
        case .some(true):
            speakToChatMenuItem.title = "Speak-to-Chat: ON"
            speakToChatMenuItem.state = .on
        case .some(false):
            speakToChatMenuItem.title = "Speak-to-Chat: OFF"
            speakToChatMenuItem.state = .off
        case .none:
            speakToChatMenuItem.title = "Speak-to-Chat: …"
            speakToChatMenuItem.state = .off
        }
    }

    // MARK: - Menu actions

    @objc private func toggleTouchSensor() {
        controller.toggleTouchSensor()
    }

    @objc private func setNCFromMenu(_ sender: NSMenuItem) {
        let mode: HeadphonesController.NCMode
        switch sender.tag {
        case 0: mode = .noiseCancelling
        case 1: mode = .ambient
        default: mode = .off
        }
        controller.setNCMode(mode)
    }

    @objc private func toggleSpeakToChat() {
        controller.toggleSpeakToChat()
    }

    @objc private func toggleAutoOff() {
        controller.autoOffEnabled.toggle()
    }

    @objc private func powerOff() {
        controller.powerOff()
    }

    @objc private func reconnect() {
        controller.connect()
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.url])
    }
}
