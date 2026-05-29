import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller = HeadphonesController()
    private let popupMenu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    private let batteryMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeSlider = NSSlider()
    private let volumeController = VolumeController(nameHints: SupportedDevices.nameHints)
    private let eqPresetMenuItem = NSMenuItem(title: "Equalizer: —", action: nil, keyEquivalent: "")
    private let eqPresetSubmenu = NSMenu(title: "Equalizer")
    private let eqPresetListItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let eqPresetListView = EqPresetListView()
    private var eqSubmenuBuilt = false
    private let eqBandsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let eqView = EqualizerView()
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
        // No eager connect — ConnectionPolicy will dial up when audio
        // starts playing or the user opens the menu.
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

        configureVolumeItem()
        popupMenu.addItem(volumeMenuItem)

        eqPresetMenuItem.submenu = eqPresetSubmenu
        eqPresetMenuItem.isHidden = true
        popupMenu.addItem(eqPresetMenuItem)

        // The preset list and band sliders live inside the Equalizer
        // submenu (collapsed by default). Both are custom views so a click
        // doesn't dismiss the menu — presets can be auditioned in place.
        eqPresetListView.onSelect = { [weak self] id in self?.controller.setEqPreset(id) }
        eqPresetListItem.view = eqPresetListView
        eqView.onBandsChanged = { [weak self] bands in self?.controller.setEqBands(bands) }
        eqBandsMenuItem.view = eqView

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

    private func configureVolumeItem() {
        let width: CGFloat = 230
        let height: CGFloat = 26
        let leftInset: CGFloat = 38
        let rightInset: CGFloat = 14
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // NSMenu stretches a custom item view to the menu's content width
        // when its autoresizing mask is flexible-width.
        container.autoresizingMask = [.width]

        let icon = NSImageView(frame: NSRect(x: 14, y: 5, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                             accessibilityDescription: "Volume")
        icon.contentTintColor = .secondaryLabelColor
        icon.autoresizingMask = [.maxXMargin]   // pinned to the left
        container.addSubview(icon)

        volumeSlider.frame = NSRect(x: leftInset, y: 3,
                                    width: width - leftInset - rightInset, height: 20)
        // Fixed left/right margins, flexible width → grows with the menu.
        volumeSlider.autoresizingMask = [.width]
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        container.addSubview(volumeSlider)

        volumeMenuItem.view = container
        volumeMenuItem.isHidden = true
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        volumeController.setVolume(Float(sender.doubleValue))
    }

    private func refreshVolumeItem(reachable: Bool) {
        if reachable, let vol = volumeController.currentVolume() {
            volumeSlider.floatValue = vol
            volumeMenuItem.isHidden = false
        } else {
            volumeMenuItem.isHidden = true
        }
    }

    // MARK: - Click routing

    @objc private func handleClick(_ sender: Any?) {
        showMenu()
    }

    private func showMenu() {
        statusItem.menu = popupMenu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Counts as user activity — wakes the RFCOMM channel if the
        // policy had idle-disconnected it.
        controller.userActivity()
        // Pull the live output volume right before the menu is shown.
        refreshVolumeItem(reachable: controller.state.deviceReachable)
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

        // Dim the menu-bar icon only when the headphones are actually
        // unreachable (off / out of range). While they're present but our
        // SPP channel is closed for battery saving ("idle"), the icon
        // stays normal. appearsDisabled is cosmetic — button stays clickable.
        statusItem.button?.appearsDisabled = !state.deviceReachable

        if let level = state.batteryLevel {
            let suffix = state.batteryCharging ? " (charging)" : ""
            batteryMenuItem.title = "Battery: \(level)%\(suffix)"
            batteryMenuItem.isHidden = false
        } else {
            batteryMenuItem.isHidden = true
        }

        // Hide the volume slider when the headphones aren't reachable.
        // (The live value is pulled in menuWillOpen so we don't fight a
        // user mid-drag with a stray state update.)
        if !state.deviceReachable {
            volumeMenuItem.isHidden = true
        }

        // Equalizer (only once the device has reported its preset list)
        if state.isConnected && !state.eqPresets.isEmpty {
            updateEqSubmenu(presets: state.eqPresets, current: state.eqCurrentPresetId)
            let currentName = state.eqPresets.first { $0.id == state.eqCurrentPresetId }?.name ?? "—"
            eqPresetMenuItem.title = "Equalizer: \(currentName)"
            eqPresetMenuItem.isHidden = false
            eqView.setBands(state.eqBands)
        } else {
            eqPresetMenuItem.isHidden = true
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

    private func updateEqSubmenu(presets: [HeadphonesController.EqPreset], current: UInt8?) {
        if !eqSubmenuBuilt {
            eqSubmenuBuilt = true
            eqPresetSubmenu.removeAllItems()
            eqPresetSubmenu.addItem(eqPresetListItem)   // custom preset rows
            eqPresetSubmenu.addItem(.separator())
            eqPresetSubmenu.addItem(eqBandsMenuItem)    // custom band sliders
        }
        eqPresetListView.setPresets(presets, current: current)
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
