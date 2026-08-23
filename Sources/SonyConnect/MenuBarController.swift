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

    private let multipointMenuItem = NSMenuItem(
        title: "Multipoint",
        action: nil,
        keyEquivalent: ""
    )
    private let multipointSubmenu = NSMenu(title: "Multipoint")
    private var multipointButtons: [String: NSButton] = [:]
    private var multipointConnectionButtons: [String: NSButton] = [:]
    private let multipointEnabledButton = NSButton()
    private var multipointLayoutSignature = ""

    private let touchMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let touchButton = NSButton()

    private let ncParentMenuItem = NSMenuItem(title: "Noise Cancelling: —", action: nil, keyEquivalent: "")
    private let ncOnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncAmbientItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncOffItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncOnButton = NSButton()
    private let ncAmbientButton = NSButton()
    private let ncOffButton = NSButton()
    private let ambientSettingsMenuItem = NSMenuItem(title: "Ambient Sound Settings", action: nil, keyEquivalent: "")
    private let ambientSettingsSubmenu = NSMenu(title: "Ambient Sound Settings")
    private let ambientLevelMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ambientLevelSlider = ScrollableSlider()
    private let focusOnVoiceMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let focusOnVoiceButton = NSButton()

    private let speakToChatMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let speakToChatButton = NSButton()

    private let autoOffMenuItem = NSMenuItem(title: "Auto Power Off", action: nil, keyEquivalent: "")
    private let autoOffSubmenu = NSMenu(title: "Auto Power Off")
    private var autoOffButtons: [Int: NSButton] = [:]
    private let powerOffMenuItem = NSMenuItem(title: "Power Off Headphones", action: nil, keyEquivalent: "")
    private let reconnectMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let reconnectButton = NSButton()
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let showBatteryMenuItem = NSMenuItem(title: "Show Battery in Menu Bar", action: nil, keyEquivalent: "")
    private let hideIconMenuItem = NSMenuItem(title: "Hide Icon When Disconnected", action: nil, keyEquivalent: "")
    private let openLogMenuItem = NSMenuItem(title: "Open Log…", action: nil, keyEquivalent: "")
    private let preferences = AppPreferences.shared
    private let launchAtLogin = LaunchAtLoginManager()
    private var hasRestoredMenuAccess = true
    private var recoveryHideWorkItem: DispatchWorkItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without an autosaveName, macOS doesn't remember a dragged position
        // across the item disappearing and reappearing (isVisible toggling
        // below) — it just re-inserts wherever. This keys the position to a
        // stable name so a manual drag sticks across connect/disconnect.
        statusItem.autosaveName = "SonyConnectStatusItem"
        super.init()
        configureStatusButton()
        configureMenu()
        updateLaunchAtLoginMenuItem()
        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.render(state: state) }
        }
        render(state: controller.state)
        // No eager connect — ConnectionPolicy will dial up when audio
        // starts playing or the user opens the menu.
    }

    // MARK: - Icon

    private func applyIcon() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(
            systemSymbolName: "airpodsmax",
            accessibilityDescription: "SonyConnect"
        ) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else {
            button.image = nil
            button.title = "🎧"
        }
    }

    private func updateStatusItemAppearance(state: HeadphonesController.State) {
        guard let button = statusItem.button else { return }

        let batteryText: String?
        if preferences.showBatteryInMenuBar,
           state.deviceReachable,
           let level = state.batteryLevel {
            batteryText = "\(level)%"
        } else {
            batteryText = nil
        }

        if let image = NSImage(
            systemSymbolName: "airpodsmax",
            accessibilityDescription: "SonyConnect"
        ) {
            image.isTemplate = true
            button.image = image
            button.imageScaling = .scaleProportionallyDown

            if let batteryText {
                // Icon + percentage needs a variable-width status item.
                button.imagePosition = .imageLeading
                button.title = " \(batteryText)"
                statusItem.length = NSStatusItem.variableLength
            } else {
                // Do not use imageLeading with an empty title. Keep the
                // ordinary disconnected/idle presentation as a square icon.
                button.imagePosition = .imageOnly
                button.title = ""
                statusItem.length = NSStatusItem.squareLength
            }
        } else {
            button.image = nil
            button.imagePosition = .noImage

            if let batteryText {
                button.title = "🎧 \(batteryText)"
                statusItem.length = NSStatusItem.variableLength
            } else {
                button.title = "🎧"
                statusItem.length = NSStatusItem.squareLength
            }
        }

        // Visibility is still controlled separately by the user's
        // Hide Icon When Disconnected preference.
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

        multipointMenuItem.submenu = multipointSubmenu
        multipointMenuItem.isHidden = true
        popupMenu.addItem(multipointMenuItem)

        popupMenu.addItem(.separator())

        configurePersistentButton(
            touchButton,
            in: touchMenuItem,
            title: "Touch Sensor",
            type: .switch,
            action: #selector(toggleTouchSensorButton(_:))
        )
        popupMenu.addItem(touchMenuItem)

        // Noise Cancelling submenu. Custom radio-button views keep the
        // submenu open while modes are changed.
        let ncSubmenu = NSMenu(title: "Noise Cancelling")

        configurePersistentButton(
            ncOnButton,
            in: ncOnItem,
            title: "Noise Cancelling",
            type: .radio,
            action: #selector(setNCFromButton(_:)),
            tag: 0
        )

        configurePersistentButton(
            ncAmbientButton,
            in: ncAmbientItem,
            title: "Ambient Sound",
            type: .radio,
            action: #selector(setNCFromButton(_:)),
            tag: 1
        )

        configurePersistentButton(
            ncOffButton,
            in: ncOffItem,
            title: "Off",
            type: .radio,
            action: #selector(setNCFromButton(_:)),
            tag: 2
        )

        ncSubmenu.addItem(ncOnItem)
        ncSubmenu.addItem(ncAmbientItem)
        ncSubmenu.addItem(ncOffItem)
        ncSubmenu.addItem(.separator())
        configureAmbientLevelItem()
        ambientSettingsSubmenu.addItem(ambientLevelMenuItem)
        ambientSettingsSubmenu.addItem(.separator())
        configurePersistentButton(
            focusOnVoiceButton,
            in: focusOnVoiceMenuItem,
            title: "Focus on Voice",
            type: .switch,
            action: #selector(toggleFocusOnVoiceButton(_:))
        )
        ambientSettingsSubmenu.addItem(focusOnVoiceMenuItem)
        ambientSettingsMenuItem.submenu = ambientSettingsSubmenu
        ncSubmenu.addItem(ambientSettingsMenuItem)

        ncParentMenuItem.submenu = ncSubmenu
        popupMenu.addItem(ncParentMenuItem)

        configurePersistentButton(
            speakToChatButton,
            in: speakToChatMenuItem,
            title: "Speak-to-Chat",
            type: .switch,
            action: #selector(toggleSpeakToChatButton(_:))
        )
        popupMenu.addItem(speakToChatMenuItem)

        popupMenu.addItem(.separator())

        autoOffMenuItem.submenu = autoOffSubmenu
        popupMenu.addItem(autoOffMenuItem)

        powerOffMenuItem.target = self
        powerOffMenuItem.action = #selector(powerOff)
        popupMenu.addItem(powerOffMenuItem)

        popupMenu.addItem(.separator())

        configurePersistentActionButton(
            reconnectButton,
            in: reconnectMenuItem,
            title: "Reconnect",
            action: #selector(reconnectButtonPressed(_:))
        )
        popupMenu.addItem(reconnectMenuItem)

        showBatteryMenuItem.target = self
        showBatteryMenuItem.action = #selector(toggleShowBatteryInMenuBar)
        popupMenu.addItem(showBatteryMenuItem)

        hideIconMenuItem.target = self
        hideIconMenuItem.action = #selector(toggleHideIcon)
        popupMenu.addItem(hideIconMenuItem)

        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.action = #selector(toggleLaunchAtLogin)
        popupMenu.addItem(launchAtLoginMenuItem)

        openLogMenuItem.target = self
        openLogMenuItem.action = #selector(openLog)
        popupMenu.addItem(openLogMenuItem)

        popupMenu.addItem(.separator())
        popupMenu.addItem(NSMenuItem(title: "Quit SonyConnect",
                                     action: #selector(NSApplication.terminate(_:)),
                                     keyEquivalent: "q"))
    }

    private func configurePersistentButton(
        _ button: NSButton,
        in menuItem: NSMenuItem,
        title: String,
        type: NSButton.ButtonType,
        action: Selector,
        tag: Int = 0
    ) {
        let width: CGFloat = 230
        let height: CGFloat = 24

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        container.autoresizingMask = [.width]

        button.frame = NSRect(x: 12, y: 1, width: width - 24, height: 22)
        button.autoresizingMask = [.width]
        button.title = title
        button.setButtonType(type)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        button.target = self
        button.action = action
        button.tag = tag

        container.addSubview(button)
        menuItem.view = container
    }

    private func configurePersistentActionButton(
        _ button: NSButton,
        in menuItem: NSMenuItem,
        title: String,
        action: Selector
    ) {
        let width: CGFloat = 230
        let height: CGFloat = 24

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        container.autoresizingMask = [.width]

        // NSMenu already provides the outer menu inset for a custom item view.
        // A small internal inset lines this title up with native menu rows.
        button.frame = NSRect(
            x: 12,
            y: 1,
            width: width - 24,
            height: 22
        )
        button.autoresizingMask = [.width]
        button.title = title
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        button.target = self
        button.action = action
        button.isEnabled = true

        container.addSubview(button)
        menuItem.view = container
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
        volumeMenuItem.isHidden = false
        volumeSlider.isEnabled = false
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        volumeController.setVolume(Float(sender.doubleValue))
    }

    private func configureAmbientLevelItem() {
        let width: CGFloat = 230
        let height: CGFloat = 40
        let leftInset: CGFloat = 38
        let rightInset: CGFloat = 14
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.autoresizingMask = [.width]

        let icon = NSImageView(frame: NSRect(x: 14, y: 19, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                             accessibilityDescription: "Ambient Sound Level")
        icon.contentTintColor = .secondaryLabelColor
        icon.autoresizingMask = [.maxXMargin]
        container.addSubview(icon)

        ambientLevelSlider.frame = NSRect(x: leftInset, y: 15,
                                          width: width - leftInset - rightInset, height: 24)
        ambientLevelSlider.autoresizingMask = [.width]
        ambientLevelSlider.minValue = 0
        ambientLevelSlider.maxValue = Double(HeadphonesController.maxAmbientLevel)
        ambientLevelSlider.isContinuous = false   // commit on mouse-up, don't flood RFCOMM
        // One tick per integer step so drags snap and the notches are
        // visible, matching the official app's stepped feel.
        ambientLevelSlider.numberOfTickMarks = Int(HeadphonesController.maxAmbientLevel) + 1
        ambientLevelSlider.allowsTickMarkValuesOnly = true
        ambientLevelSlider.tickMarkPosition = .below
        ambientLevelSlider.target = self
        ambientLevelSlider.action = #selector(ambientLevelChanged(_:))
        container.addSubview(ambientLevelSlider)

        let minLabel = NSTextField(labelWithString: "0")
        minLabel.font = .systemFont(ofSize: 9)
        minLabel.textColor = .secondaryLabelColor
        minLabel.frame = NSRect(x: leftInset, y: 2, width: 24, height: 11)
        container.addSubview(minLabel)

        let maxLabel = NSTextField(labelWithString: "\(Int(HeadphonesController.maxAmbientLevel))")
        maxLabel.font = .systemFont(ofSize: 9)
        maxLabel.textColor = .secondaryLabelColor
        maxLabel.alignment = .right
        maxLabel.frame = NSRect(x: width - rightInset - 24, y: 2, width: 24, height: 11)
        maxLabel.autoresizingMask = [.minXMargin]
        container.addSubview(maxLabel)

        ambientLevelMenuItem.view = container
    }

    @objc private func ambientLevelChanged(_ sender: NSSlider) {
        controller.setAmbientLevel(sender.integerValue)
    }

    private func refreshVolumeItem(reachable: Bool) {
        guard reachable, let vol = volumeController.currentVolume() else {
            volumeSlider.isEnabled = false
            return
        }

        volumeSlider.floatValue = vol
        volumeSlider.isEnabled = true
    }

    // MARK: - Click routing

    @objc private func handleClick(_ sender: Any?) {
        showMenu()
    }

    private func showMenu() {
        statusItem.menu = popupMenu
        statusItem.button?.performClick(nil)
    }

    func revealForRecovery() {
        guard preferences.hideIconWhenDisconnected,
              !controller.state.deviceReachable else { return }

        recoveryHideWorkItem?.cancel()
        hasRestoredMenuAccess = true
        render(state: controller.state)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.statusItem.menu !== self.popupMenu else { return }
            self.hasRestoredMenuAccess = false
            self.render(state: self.controller.state)
        }
        recoveryHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        hasRestoredMenuAccess = true
        updateLaunchAtLoginMenuItem()
        // Keep the Sony control channel alive for the entire time the
        // user is interacting with the menu.
        controller.menuOpened()

        // Pull the live output volume right before the menu is shown.
        refreshVolumeItem(reachable: controller.state.deviceReachable)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Start the RFCOMM release grace period only after the menu closes.
        controller.menuClosed()

        if preferences.hideIconWhenDisconnected && !controller.state.deviceReachable {
            hasRestoredMenuAccess = false
            render(state: controller.state)
        }

        // Detach the menu so the next click is routed through our action
        // handler again.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - State → UI

    private func refreshOpenMenuUI() {
        guard statusItem.menu === popupMenu else { return }

        // AppKit's menu tracking loop does not always repaint items whose
        // state changes asynchronously while the menu is already open.
        // Force both native menu items and custom-view rows to refresh.
        popupMenu.update()

        for item in popupMenu.items {
            if let view = item.view {
                view.needsLayout = true
                view.needsDisplay = true
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
            }

            item.submenu?.update()
        }
    }

    private func render(state: HeadphonesController.State) {
        defer { refreshOpenMenuUI() }
        statusMenuItem.title = state.statusDescription
        reconnectMenuItem.isHidden = state.isConnected
        reconnectButton.isEnabled = true
        updateAutoOffSubmenu(state: state)

        // Default: the icon stays put and dims while the headphones are
        // unreachable — Quit has to stay clickable since there's no Dock icon.
        // Hiding the icon entirely is opt-in (defaults write com.tanat.sonyconnect
        // HideIconWhenDisconnected -bool YES, or the toggle below): it looks
        // tidier, but while hidden the app is only reachable again by
        // reconnecting the headphones or flipping the default back.
        showBatteryMenuItem.state = preferences.showBatteryInMenuBar ? .on : .off
        hideIconMenuItem.state = preferences.hideIconWhenDisconnected ? .on : .off

        updateStatusItemAppearance(state: state)
        if preferences.hideIconWhenDisconnected {
            // Keep the item visible until the user has had a chance to open
            // the menu and turn this preference off after relaunch.
            statusItem.isVisible = state.deviceReachable || hasRestoredMenuAccess
            statusItem.button?.appearsDisabled = false
        } else {
            statusItem.isVisible = true
            statusItem.button?.appearsDisabled = !state.deviceReachable
        }

        if let level = state.batteryLevel {
            let charging = state.batteryCharging ? " (charging)" : ""
            let stale = state.isConnected ? "" : " (Last Known)"
            batteryMenuItem.title = "Battery: \(level)%\(charging)\(stale)"
            batteryMenuItem.isHidden = false
        } else {
            batteryMenuItem.isHidden = true
        }

        // Volume is Mac-side CoreAudio state, not Sony protocol state.
        // Refresh it whenever headphone reachability changes so an already-open
        // menu becomes interactive immediately after the headphones reconnect.
        refreshVolumeItem(reachable: state.deviceReachable)

        // Retain the most recently reported EQ while RFCOMM is idle.
        // Its submenu is informational only until a live control session exists.
        if !state.eqPresets.isEmpty {
            updateEqSubmenu(presets: state.eqPresets, current: state.eqCurrentPresetId)
            let currentName = state.eqPresets.first { $0.id == state.eqCurrentPresetId }?.name ?? "—"
            eqPresetMenuItem.title = "Equalizer: \(currentName)"
            eqPresetMenuItem.isHidden = false
            eqPresetMenuItem.isEnabled = state.isConnected
            eqView.setBands(state.eqBands)
        } else {
            eqPresetMenuItem.isHidden = true
        }

        updateMultipointSubmenu(state: state)

        // Second-generation devices expose no touch-panel setting and no
        // verified power-off opcode, so hide both instead of showing controls
        // that would silently do nothing. Set before the disconnected early
        // return so the rows reappear once a v1 device connects.

        if !state.isConnected {
            // Show cached Sony state, but never allow stale controls to send
            // commands until a fresh RFCOMM session is initialized.
            touchButton.title = "Touch Sensor"
            touchButton.state = state.touchSensorEnabled == true ? .on : .off
            touchButton.isEnabled = false

            let ncLabel: String
            switch state.ncMode {
            case .some(.noiseCancelling): ncLabel = "ON"
            case .some(.ambient): ncLabel = "Ambient"
            case .some(.off): ncLabel = "Off"
            case .none: ncLabel = "—"
            }
            ncParentMenuItem.title = state.ncMode == nil
                ? "Noise Cancelling: —"
                : "Noise Cancelling: \(ncLabel)"
            ncParentMenuItem.isEnabled = true

            ncOnButton.state = state.ncMode == .noiseCancelling ? .on : .off
            ncAmbientButton.state = state.ncMode == .ambient ? .on : .off
            ncOffButton.state = state.ncMode == .off ? .on : .off
            ncOnButton.isEnabled = false
            ncAmbientButton.isEnabled = false
            ncOffButton.isEnabled = false

            ambientSettingsMenuItem.isEnabled = false
            ambientLevelSlider.integerValue = state.ambientLevel
            focusOnVoiceButton.state = state.ambientFocusOnVoice ? .on : .off
            focusOnVoiceButton.isEnabled = false

            speakToChatButton.title = "Speak-to-Chat"
            speakToChatButton.state = state.speakToChatEnabled == true ? .on : .off
            speakToChatButton.isEnabled = false

            powerOffMenuItem.isEnabled = false
            return
        }
        // Touch sensor row
        switch state.touchSensorEnabled {
        case .some(true):
            touchButton.title = "Touch Sensor"
            touchButton.state = .on
            touchButton.isEnabled = true
        case .some(false):
            touchButton.title = "Touch Sensor"
            touchButton.state = .off
            touchButton.isEnabled = true
        case .none:
            touchButton.title = "Touch Sensor"
            touchButton.state = .off
            touchButton.isEnabled = false
        }

        // Noise Cancelling submenu
        ncParentMenuItem.isEnabled = true
        ncOnButton.isEnabled = true
        ncAmbientButton.isEnabled = true
        ncOffButton.isEnabled = true

        let ncLabel: String
        switch state.ncMode {
        case .some(.noiseCancelling): ncLabel = "ON"
        case .some(.ambient): ncLabel = "Ambient"
        case .some(.off): ncLabel = "Off"
        case .none: ncLabel = "…"
        }
        ncParentMenuItem.title = "Noise Cancelling: \(ncLabel)"
        ncOnButton.state = state.ncMode == .noiseCancelling ? .on : .off
        ncAmbientButton.state = state.ncMode == .ambient ? .on : .off
        ncOffButton.state = state.ncMode == .off ? .on : .off

        // Ambient Sound settings (level slider + Focus on Voice) only make
        // sense while Ambient mode is actually active on the device.
        let ambientActive = state.ncMode == .ambient
        ambientSettingsMenuItem.isEnabled = ambientActive
        ambientLevelSlider.integerValue = state.ambientLevel
        focusOnVoiceButton.isEnabled = ambientActive
        focusOnVoiceButton.state = state.ambientFocusOnVoice ? .on : .off

        // Speak-to-Chat
        speakToChatButton.isEnabled = state.speakToChatEnabled != nil
        speakToChatButton.title = "Speak-to-Chat"

        switch state.speakToChatEnabled {
        case .some(true):
            speakToChatButton.state = .on
        case .some(false):
            speakToChatButton.state = .off
        case .none:
            speakToChatButton.state = .off
        }
    }

    private func updateMultipointSubmenu(state: HeadphonesController.State) {
        let hasAnyMultipointUI =
            state.multipointToggleAvailable ||
            !state.connectedDevices.isEmpty

        guard state.isWH1000XM6, hasAnyMultipointUI else {
            multipointMenuItem.isHidden = true
            multipointLayoutSignature = ""
            multipointButtons.removeAll()
            multipointConnectionButtons.removeAll()
            multipointSubmenu.removeAllItems()
            return
        }

        multipointMenuItem.isHidden = false

        func addHeader(_ title: String) {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

            let width: CGFloat = 230
            let height: CGFloat = 24

            let container = NSView(
                frame: NSRect(x: 0, y: 0, width: width, height: height)
            )
            container.autoresizingMask = [.width]

            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .semibold
            )
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(
                x: 12,
                y: 3,
                width: width - 24,
                height: 18
            )
            label.autoresizingMask = [.width]

            container.addSubview(label)
            item.view = container

            multipointSubmenu.addItem(item)
        }

        let connected = state.connectedDevices
            .filter { $0.isConnected }
            .sorted {
                ($0.connectionSlot ?? Int.max) <
                ($1.connectionSlot ?? Int.max)
            }

        let disconnected = state.connectedDevices
            .filter { !$0.isConnected }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) ==
                .orderedAscending
            }

        if state.multipointEnabled == false {
            multipointMenuItem.title = "Multipoint: Off"
        } else if state.connectedDevicesAreLive {
            multipointMenuItem.title =
                "Multipoint: \(connected.count) Connected"
        } else {
            multipointMenuItem.title = "Multipoint: Last Known"
        }

        // Playback-right changes and multipoint ON/OFF changes should update
        // existing custom controls in-place. Only rebuild when the actual
        // device/layout structure changes.
        let signature =
            "toggle=\(state.multipointToggleAvailable)" +
            "|manage=\(state.multipointDeviceManagementAvailable)" +
            "|live=\(state.connectedDevicesAreLive)" +
            "|connected=" +
            connected.map {
                "\($0.address)|\($0.name)|\($0.connectionSlot ?? 0)"
            }.joined(separator: ";") +
            "|known=" +
            disconnected.map {
                "\($0.address)|\($0.name)"
            }.joined(separator: ";")

        if signature != multipointLayoutSignature {
            multipointLayoutSignature = signature
            multipointButtons.removeAll()
            multipointConnectionButtons.removeAll()
            multipointSubmenu.removeAllItems()

            if state.multipointToggleAvailable {
                let item = NSMenuItem(
                    title: "",
                    action: nil,
                    keyEquivalent: ""
                )

                configurePersistentButton(
                    multipointEnabledButton,
                    in: item,
                    title: "Connect to 2 Devices Simultaneously",
                    type: .switch,
                    action: #selector(toggleMultipointEnabledFromButton(_:))
                )

                multipointSubmenu.addItem(item)

                if !state.connectedDevices.isEmpty {
                    multipointSubmenu.addItem(.separator())
                }
            }

            if !state.connectedDevicesAreLive {
                if !state.connectedDevices.isEmpty {
                    addHeader("Known Devices")

                    for device in state.connectedDevices.sorted(by: {
                        $0.name.localizedCaseInsensitiveCompare($1.name) ==
                        .orderedAscending
                    }) {
                        let item = NSMenuItem(
                            title: device.name,
                            action: nil,
                            keyEquivalent: ""
                        )
                        item.isEnabled = false
                        item.toolTip = device.address
                        multipointSubmenu.addItem(item)
                    }
                }
            } else {
                if !connected.isEmpty {
                    addHeader("Connected")

                    for device in connected {
                        let item = NSMenuItem(
                            title: "",
                            action: nil,
                            keyEquivalent: ""
                        )

                        let button = NSButton()

                        configurePersistentButton(
                            button,
                            in: item,
                            title: device.name,
                            type: .switch,
                            action: #selector(selectMultipointPlaybackDevice(_:))
                        )

                        button.identifier =
                            NSUserInterfaceItemIdentifier(device.address)

                        multipointButtons[device.address] = button
                        multipointSubmenu.addItem(item)
                    }
                }

                if !connected.isEmpty && !disconnected.isEmpty {
                    multipointSubmenu.addItem(.separator())
                }

                if !disconnected.isEmpty {
                    addHeader("Known Devices")

                    for device in disconnected {
                        if state.multipointDeviceManagementAvailable {
                            let item = NSMenuItem(
                                title: "",
                                action: nil,
                                keyEquivalent: ""
                            )

                            let button = NSButton()

                            configurePersistentActionButton(
                                button,
                                in: item,
                                title: device.name,
                                action: #selector(
                                    multipointConnectionButtonPressed(_:)
                                )
                            )

                            button.identifier =
                                NSUserInterfaceItemIdentifier(
                                    "connect|\(device.address)"
                                )
                            button.toolTip = "Connect \(device.name)"

                            multipointConnectionButtons[
                                "connect|\(device.address)"
                            ] = button

                            multipointSubmenu.addItem(item)
                        } else {
                            let item = NSMenuItem(
                                title: device.name,
                                action: nil,
                                keyEquivalent: ""
                            )
                            item.isEnabled = false
                            item.toolTip = device.address
                            multipointSubmenu.addItem(item)
                        }
                    }
                }

                // A connected-device click remains playback-source selection.
                // Keep disconnect explicit so the two operations cannot be
                // confused accidentally.
                if state.multipointDeviceManagementAvailable &&
                    !connected.isEmpty {
                    multipointSubmenu.addItem(.separator())
                    addHeader("Disconnect")

                    for device in connected {
                        let item = NSMenuItem(
                            title: "",
                            action: nil,
                            keyEquivalent: ""
                        )

                        let button = NSButton()

                        configurePersistentActionButton(
                            button,
                            in: item,
                            title: device.name,
                            action: #selector(
                                multipointConnectionButtonPressed(_:)
                            )
                        )

                        button.identifier =
                            NSUserInterfaceItemIdentifier(
                                "disconnect|\(device.address)"
                            )
                        button.toolTip = "Disconnect \(device.name)"

                        multipointConnectionButtons[
                            "disconnect|\(device.address)"
                        ] = button

                        multipointSubmenu.addItem(item)
                    }
                }
            }
        }

        // Update values without rebuilding the currently tracked menu.
        let displayedMultipointEnabled =
            state.pendingMultipointEnabled ??
            state.multipointEnabled

        multipointEnabledButton.state =
            displayedMultipointEnabled == true ? .on : .off

        multipointEnabledButton.isEnabled =
            state.isConnected &&
            state.multipointToggleAvailable &&
            state.multipointEnabled != nil &&
            state.pendingMultipointEnabled == nil

        for device in connected {
            guard let button = multipointButtons[device.address] else {
                continue
            }

            let isPlaybackDevice =
                device.connectionSlot == state.playbackDeviceSlot

            button.state = isPlaybackDevice ? .on : .off
            button.isEnabled =
                state.isConnected &&
                state.multipointEnabled != false

            button.toolTip = [
                device.address,
                device.connectionSlot.map { "Multipoint slot \($0)" },
                isPlaybackDevice ? "Current playback device" : nil
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        }

        for button in multipointConnectionButtons.values {
            button.isEnabled =
                state.isConnected &&
                state.multipointDeviceManagementAvailable &&
                state.multipointEnabled != false
        }
    }

    @objc private func selectMultipointPlaybackDevice(_ sender: NSButton) {
        guard let address = sender.identifier?.rawValue else { return }

        controller.switchMultipointPlayback(to: address)

        // Restore the last confirmed state until Sony replies.
        updateMultipointSubmenu(state: controller.state)
    }

    @objc private func toggleMultipointEnabledFromButton(_ sender: NSButton) {
        let desired = sender.state == .on
        controller.setMultipointEnabled(desired)

        // Keep UI authoritative to the headset's D7/D9 response.
        updateMultipointSubmenu(state: controller.state)
    }

    @objc private func multipointConnectionButtonPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }

        let parts = raw.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        guard parts.count == 2 else { return }

        let action = String(parts[0])
        let address = String(parts[1])

        switch action {
        case "connect":
            controller.setMultipointDeviceConnected(
                true,
                address: address
            )

        case "disconnect":
            controller.setMultipointDeviceConnected(
                false,
                address: address
            )

        default:
            return
        }
    }

    // MARK: - Menu actions

    @objc private func toggleTouchSensorButton(_ sender: NSButton) {
        controller.toggleTouchSensor()
    }

    @objc private func setNCFromButton(_ sender: NSButton) {
        let mode: HeadphonesController.NCMode

        switch sender.tag {
        case 0:
            mode = .noiseCancelling
        case 1:
            mode = .ambient
        default:
            mode = .off
        }

        controller.setNCMode(mode)
    }

    @objc private func toggleSpeakToChatButton(_ sender: NSButton) {
        controller.toggleSpeakToChat()
    }

    @objc private func toggleFocusOnVoiceButton(_ sender: NSButton) {
        controller.setAmbientFocusOnVoice(sender.state == .on)
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

    // Rebuilt on demand: "When taken off" only exists on v2, so the option
    // list depends on the connected device.
    private func updateAutoOffSubmenu(state: HeadphonesController.State) {
        let options = AutoPowerOffOption.selectable(
            isV2: state.protocolIsV2,
            isXM6: state.isWH1000XM6
        )
        if autoOffSubmenu.items.count != options.count {
            autoOffSubmenu.removeAllItems()
            autoOffButtons.removeAll()

            for option in options {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let button = NSButton()

                configurePersistentButton(
                    button,
                    in: item,
                    title: option.title,
                    type: .radio,
                    action: #selector(setAutoOffFromButton(_:)),
                    tag: option.rawValue
                )

                autoOffButtons[option.rawValue] = button
                autoOffSubmenu.addItem(item)
            }
        }

        for option in options {
            autoOffButtons[option.rawValue]?.state =
                option == state.autoOffOption ? .on : .off
        }
        let autoOffValue = state.autoOffOption == .off
            ? "Off"
            : state.autoOffOption.title
        autoOffMenuItem.title = "Auto Power Off: \(autoOffValue)"
        autoOffMenuItem.isEnabled = state.isConnected
    }

    @objc private func setAutoOffFromButton(_ sender: NSButton) {
        guard let option = AutoPowerOffOption(rawValue: sender.tag) else { return }
        controller.autoOffOption = option
    }

    @objc private func powerOff() {
        controller.powerOff()
    }

    @objc private func reconnectButtonPressed(_ sender: NSButton) {
        controller.connect()
    }

    @objc private func toggleShowBatteryInMenuBar() {
        preferences.showBatteryInMenuBar.toggle()
        render(state: controller.state)
    }

    @objc private func toggleHideIcon() {
        preferences.hideIconWhenDisconnected.toggle()
        render(state: controller.state)
    }

    @objc private func toggleLaunchAtLogin() {
        let result = launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        switch result {
        case .changed:
            updateLaunchAtLoginMenuItem()
        case .unsupported:
            showLaunchAtLoginAlert(
                message: "Launch at Login requires macOS 13 or later."
            )
        case .failed(let error):
            FileLogger.shared.log("login", "could not change registration: \(error.localizedDescription)")
            showLaunchAtLoginAlert(
                message: "SonyConnect could not change its Launch at Login setting.\n\n\(error.localizedDescription)"
            )
        }
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginMenuItem.state = launchAtLogin.isEnabled ? .on : .off
        launchAtLoginMenuItem.isEnabled = launchAtLogin.isSupported
    }

    private func showLaunchAtLoginAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Launch at Login"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateLaunchAtLoginMenuItem()
    }

    @objc private func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.url])
    }
}
