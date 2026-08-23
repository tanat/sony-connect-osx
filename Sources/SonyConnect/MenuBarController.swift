import AppKit
import UserNotifications

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller = HeadphonesController()
    private let popupMenu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
    private let batteryMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeSlider = NSSlider()
    private let volumeController = VolumeController(nameHints: SupportedDevices.nameHints)
    private var volumeRefreshTimer: Timer?
    private let eqPresetMenuItem = NSMenuItem(title: "Equalizer: —", action: nil, keyEquivalent: "")
    private let eqPresetSubmenu = NSMenu(title: "Equalizer")
    private let eqPresetListItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let eqPresetListView = EqPresetListView()
    private var eqSubmenuBuilt = false
    private let eqBandsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let eqView = EqualizerView()

    private let multipointMenuItem = NSMenuItem(
        title: "",
        action: nil,
        keyEquivalent: ""
    )
    private let multipointManagerView = MultipointMenuView()

    private let touchMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let touchButton = NSButton()

    private let ncParentMenuItem = NSMenuItem(title: "Noise Cancelling: —", action: nil, keyEquivalent: "")
    private let ncOnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncAmbientItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncOffItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ncOnButton = NSButton()
    private let ncAmbientButton = NSButton()
    private let ncOffButton = NSButton()
    private let autoAmbientMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoAmbientButton = NSButton()
    private let autoAmbientSensitivityMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let autoAmbientSensitivityButton = NSButton()
    private let ambientSettingsMenuItem = NSMenuItem(title: "Ambient Sound Settings", action: nil, keyEquivalent: "")
    private let ambientSettingsSubmenu = NSMenu(title: "Ambient Sound Settings")
    private let ambientLevelMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let ambientLevelSlider = ScrollableSlider()
    private let focusOnVoiceMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let focusOnVoiceButton = NSButton()

    private let speakToChatMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let speakToChatSubmenu = NSMenu(title: "Speak-to-Chat")
    private let speakToChatButton = NSButton()
    private let speakSensitivityMenuItem = NSMenuItem(title: "Sensitivity: —", action: nil, keyEquivalent: "")
    private let speakTimeoutMenuItem = NSMenuItem(title: "Resume after: —", action: nil, keyEquivalent: "")
    private let speakSensitivityButton = NSButton()
    private let speakTimeoutButton = NSButton()
    private let speakParentMenuItem = NSMenuItem(title: "Speak-to-Chat", action: nil, keyEquivalent: "")

    private let wearingMenuItem = NSMenuItem(title: "Wearing Detection", action: nil, keyEquivalent: "")
    private let pauseWhenTakenOffMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseWhenTakenOffButton = NSButton()

    private let listeningModesMenuItem = NSMenuItem(title: "Listening Mode", action: nil, keyEquivalent: "")
    private let listeningModesSubmenu = NSMenu(title: "Listening Mode")
    private let listeningModeContentItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let standardListeningItem = NSMenuItem(title: "Standard", action: nil, keyEquivalent: "")
    private let backgroundMusicListeningItem = NSMenuItem(title: "Background Music", action: nil, keyEquivalent: "")
    private let cinemaListeningItem = NSMenuItem(title: "Cinema", action: nil, keyEquivalent: "")
    private let bgmRoomSizeMenuItem = NSMenuItem(title: "Background Music Room", action: nil, keyEquivalent: "")
    private let bgmRoomSizeSubmenu = NSMenu(title: "Background Music Room")
    private let myRoomButton = NSButton()
    private let livingRoomButton = NSButton()
    private let cafeButton = NSButton()
    private let listeningModeView = ListeningModeMenuView()

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
    private var noiseCancellingSubmenuIsOpen = false
    private var lastBatteryLevel: Int?
    private var lastBatteryCharging: Bool?

    override init() {
        // Do not assign autosaveName here. On recent macOS versions,
        // persisted status-item placement/visibility state can survive outside
        // the application's ordinary defaults and leave an otherwise healthy
        // status item invisible after relaunch/reinstall.
        //
        // Start with a compact variable-width item so macOS can place it
        // beside the notch and other menu extras. The render path keeps this
        // compact width for the icon-only state and expands it for battery text.
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        super.init()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                FileLogger.shared.log("notifications", "battery notification permission error: \(error.localizedDescription)")
            } else {
                FileLogger.shared.log("notifications", "battery notifications authorized=\(granted)")
            }
        }

        // Establish a visible status item before any asynchronous Sony state
        // arrives. User preference handling in render() may hide it later only
        // when Hide Icon When Disconnected is actually enabled.
        statusItem.isVisible = true

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
            button.title = "SC"
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
                statusItem.length = NSStatusItem.variableLength
            }
        } else {
            button.image = nil
            button.imagePosition = .noImage

            if let batteryText {
                button.title = "SC \(batteryText)"
                statusItem.length = NSStatusItem.variableLength
            } else {
                button.title = "SC"
                statusItem.length = NSStatusItem.variableLength
            }
        }

        // Visibility is still controlled separately by the user's
        // Hide Icon When Disconnected preference.
    }

    // MARK: - Setup

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        button.isHidden = false
        button.alphaValue = 1.0
        button.isEnabled = true
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

        multipointMenuItem.view = multipointManagerView

        multipointManagerView.onToggleMultipoint = {
            [weak self] enabled in

            guard let self else { return }

            self.controller.setMultipointEnabled(enabled)
            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onPlayback = {
            [weak self] address in

            guard let self else { return }

            self.controller.switchMultipointPlayback(
                to: address
            )

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onConnect = {
            [weak self] address in

            guard let self else { return }

            self.controller.setMultipointDeviceConnected(
                true,
                address: address
            )

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onDisconnect = {
            [weak self] address in

            guard let self else { return }

            self.controller.setMultipointDeviceConnected(
                false,
                address: address
            )

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onSwap = {
            [weak self] address in

            guard let self else { return }

            self.controller.swapInMultipointDevice(
                address: address
            )

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onTogglePairing = {
            [weak self] in

            guard let self else { return }

            self.controller.setPairingMode(
                self.controller.state.pairingMode != true
            )

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }

        multipointManagerView.onRefresh = {
            [weak self] in

            guard let self else { return }

            self.controller.refreshMultipointManager()

            self.multipointManagerView.render(
                state: self.controller.state
            )
        }
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
        ncSubmenu.delegate = self

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
        configurePersistentButton(
            autoAmbientButton,
            in: autoAmbientMenuItem,
            title: "Auto Ambient Sound",
            type: .switch,
            action: #selector(toggleAutoAmbientButton(_:))
        )
        configurePersistentButton(
            autoAmbientSensitivityButton,
            in: autoAmbientSensitivityMenuItem,
            title: "Sensitivity: Standard",
            type: .momentaryPushIn,
            action: #selector(cycleAutoAmbientSensitivity(_:)),
            leftInset: 48
        )
        configureAmbientLevelItem()
        ncSubmenu.addItem(ambientLevelMenuItem)
        configurePersistentButton(
            focusOnVoiceButton,
            in: focusOnVoiceMenuItem,
            title: "Focus on Voice",
            type: .switch,
            action: #selector(toggleFocusOnVoiceButton(_:))
        )
        ncSubmenu.addItem(focusOnVoiceMenuItem)
        ncSubmenu.addItem(ncOffItem)

        ncParentMenuItem.submenu = ncSubmenu
        popupMenu.addItem(ncParentMenuItem)
        popupMenu.addItem(autoAmbientMenuItem)
        popupMenu.addItem(autoAmbientSensitivityMenuItem)

        configurePersistentButton(
            speakToChatButton,
            in: speakToChatMenuItem,
            title: "Speak-to-Chat",
            type: .switch,
            action: #selector(toggleSpeakToChatButton(_:))
        )
        speakToChatSubmenu.addItem(speakToChatMenuItem)
        speakToChatSubmenu.addItem(.separator())
        configurePersistentButton(
            speakSensitivityButton,
            in: speakSensitivityMenuItem,
            title: "Sensitivity: —",
            type: .momentaryPushIn,
            action: #selector(cycleSpeakSensitivity(_:))
        )
        configurePersistentButton(
            speakTimeoutButton,
            in: speakTimeoutMenuItem,
            title: "Resume after: —",
            type: .momentaryPushIn,
            action: #selector(cycleSpeakTimeout(_:))
        )
        speakToChatSubmenu.addItem(speakSensitivityMenuItem)
        speakToChatSubmenu.addItem(speakTimeoutMenuItem)
        speakParentMenuItem.submenu = speakToChatSubmenu
        popupMenu.addItem(speakParentMenuItem)

        configurePersistentButton(
            pauseWhenTakenOffButton,
            in: wearingMenuItem,
            title: "Wearing Detection",
            type: .switch,
            action: #selector(togglePauseWhenTakenOff(_:))
        )
        // This is a single setting, so keep it directly clickable while using
        // a custom button to keep the menu open after the toggle.
        popupMenu.addItem(wearingMenuItem)

        listeningModeView.setShowsHeader(false)
        listeningModeContentItem.view = listeningModeView
        listeningModesSubmenu.addItem(listeningModeContentItem)
        listeningModesMenuItem.submenu = listeningModesSubmenu
        popupMenu.addItem(listeningModesMenuItem)

        listeningModeView.onModeChanged = { [weak self] mode in
            self?.controller.setListeningMode(mode)
        }
        listeningModeView.onRoomChanged = { [weak self] room in
            self?.controller.setBgmRoomSize(room)
        }

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

        let quitMenuItem = NSMenuItem(
            title: "Quit SonyConnect",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        popupMenu.addItem(quitMenuItem)
        reorderPopupMenu(quitMenuItem: quitMenuItem)
    }

    private func reorderPopupMenu(quitMenuItem: NSMenuItem) {
        popupMenu.removeAllItems()

        let firstGroup = [
            statusMenuItem,
            batteryMenuItem,
            volumeMenuItem,
            eqPresetMenuItem,
            multipointMenuItem
        ]
        let controlsGroup = [
            ncParentMenuItem,
            autoAmbientMenuItem,
            autoAmbientSensitivityMenuItem,
            listeningModesMenuItem,
            speakParentMenuItem,
            touchMenuItem,
            wearingMenuItem
        ]
        let powerGroup = [
            autoOffMenuItem,
            powerOffMenuItem
        ]
        let utilityGroup = [
            reconnectMenuItem,
            showBatteryMenuItem,
            hideIconMenuItem,
            launchAtLoginMenuItem,
            openLogMenuItem
        ]

        for (index, group) in [firstGroup, controlsGroup, powerGroup, utilityGroup].enumerated() {
            if index > 0 {
                popupMenu.addItem(.separator())
            }
            group.forEach { popupMenu.addItem($0) }
        }
        popupMenu.addItem(.separator())
        popupMenu.addItem(quitMenuItem)
    }

    private func configurePersistentButton(
        _ button: NSButton,
        in menuItem: NSMenuItem,
        title: String,
        type: NSButton.ButtonType,
        action: Selector,
        tag: Int = 0,
        leftInset: CGFloat = 12
    ) {
        let width: CGFloat = 230
        let height: CGFloat = 24

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        container.autoresizingMask = [.width]

        button.frame = NSRect(
            x: leftInset,
            y: 1,
            width: width - leftInset - 12,
            height: 22
        )
        button.autoresizingMask = [.width]
        button.title = title
        // Use a borderless push button for toggles and supply the same
        // leading checkmark treatment as native NSMenuItems. The switch
        // button style draws a rounded box, which does not match the rest of
        // this menu.
        button.setButtonType(type == .switch ? .pushOnPushOff : type)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        if type == .switch {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.image = menuCheckmarkImage(checked: false)
        }
        button.font = .menuFont(ofSize: 0)
        button.target = self
        button.action = action
        button.tag = tag

        container.addSubview(button)
        menuItem.view = container
    }

    private func menuCheckmarkImage(checked: Bool) -> NSImage {
        if checked {
            return NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: "Enabled"
            ) ?? NSImage(size: NSSize(width: 16, height: 16))
        }

        return NSImage(size: NSSize(width: 16, height: 16))
    }

    private func setMenuCheckmark(
        _ button: NSButton,
        checked: Bool
    ) {
        button.image = menuCheckmarkImage(checked: checked)
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
        let sliderWidth: CGFloat = 300
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

        // Use explicit constraints so AppKit cannot stretch the track to the
        // full width of the surrounding menu.
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeSlider)
        NSLayoutConstraint.activate([
            volumeSlider.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: leftInset
            ),
            volumeSlider.centerYAnchor.constraint(
                equalTo: container.centerYAnchor
            ),
            volumeSlider.widthAnchor.constraint(
                equalToConstant: sliderWidth
            ),
            volumeSlider.heightAnchor.constraint(equalToConstant: 20)
        ])
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))

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
        if menu === ncParentMenuItem.submenu {
            noiseCancellingSubmenuIsOpen = true
            return
        }

        hasRestoredMenuAccess = true
        updateLaunchAtLoginMenuItem()
        // Keep the Sony control channel alive for the entire time the
        // user is interacting with the menu.
        controller.menuOpened()

        // Pull the live output volume right before the menu is shown.
        refreshVolumeItem(reachable: controller.state.deviceReachable)
        volumeRefreshTimer?.invalidate()
        volumeRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshVolumeItem(
                reachable: self.controller.state.deviceReachable
            )
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === ncParentMenuItem.submenu {
            noiseCancellingSubmenuIsOpen = false
            return
        }

        // Start the RFCOMM release grace period only after the menu closes.
        volumeRefreshTimer?.invalidate()
        volumeRefreshTimer = nil
        controller.menuClosed()

        if preferences.hideIconWhenDisconnected && !controller.state.deviceReachable {
            hasRestoredMenuAccess = false
            render(state: controller.state)
        }

        // Detach the menu so the next click is routed through our action
        // handler again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.menu = nil
            self.updateAmbientDetailVisibility(state: self.controller.state, keepVisibleWhileSubmenuOpen: false)
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
        notifyBatteryChanges(state: state)
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
        updateDiscoveredFeatureMenus(state: state)

        // Second-generation devices expose no touch-panel setting and no
        // verified power-off opcode, so hide both instead of showing controls
        // that would silently do nothing. Set before the disconnected early
        // return so the rows reappear once a v1 device connects.

        if !state.isConnected {
            // Show cached Sony state, but never allow stale controls to send
            // commands until a fresh RFCOMM session is initialized.
            touchButton.title = "Touch Sensor"
            touchButton.state = state.touchSensorEnabled == true ? .on : .off
            setMenuCheckmark(
                touchButton,
                checked: state.touchSensorEnabled == true
            )
            touchButton.isEnabled = true

            let ncLabel: String
            switch state.ncMode {
            case .some(.noiseCancelling): ncLabel = "ON"
            case .some(.ambient): ncLabel = "Ambient"
            case .some(.off): ncLabel = "Off"
            case .none: ncLabel = "—"
            }
            ncParentMenuItem.title = state.ncMode == nil
                ? "Noise Cancelling"
                : "Noise Cancelling: \(ncLabel)"
            ncParentMenuItem.isEnabled = true

            ncOnButton.state = state.ncMode == .noiseCancelling ? .on : .off
            ncAmbientButton.state = state.ncMode == .ambient ? .on : .off
            ncOffButton.state = state.ncMode == .off ? .on : .off
            ncOnButton.isEnabled = false
            ncAmbientButton.isEnabled = false
            ncOffButton.isEnabled = false

            updateAmbientDetailVisibility(state: state, keepVisibleWhileSubmenuOpen: false)
            autoAmbientButton.state = state.autoAmbientSoundEnabled == true ? .on : .off
            setMenuCheckmark(
                autoAmbientButton,
                checked: state.autoAmbientSoundEnabled == true
            )
            autoAmbientButton.isEnabled = true
            autoAmbientSensitivityButton.title = "Sensitivity: \(state.autoAmbientSensitivity.label)"
            autoAmbientSensitivityButton.isEnabled = false
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
            setMenuCheckmark(touchButton, checked: true)
            touchButton.isEnabled = true
        case .some(false):
            touchButton.title = "Touch Sensor"
            touchButton.state = .off
            setMenuCheckmark(touchButton, checked: false)
            touchButton.isEnabled = true
        case .none:
            touchButton.title = "Touch Sensor"
            touchButton.state = .off
            setMenuCheckmark(touchButton, checked: false)
            touchButton.isEnabled = true
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
        case .none: ncLabel = ""
        }
        ncParentMenuItem.title = ncLabel.isEmpty
            ? "Noise Cancelling"
            : "Noise Cancelling: \(ncLabel)"
        ncOnButton.state = state.ncMode == .noiseCancelling ? .on : .off
        ncAmbientButton.state = state.ncMode == .ambient ? .on : .off
        ncOffButton.state = state.ncMode == .off ? .on : .off

        // Ambient Sound settings (level slider + Focus on Voice) only make
        // sense while Ambient mode is actually active on the device.
        let ambientActive = state.ncMode == .ambient
        updateAmbientDetailVisibility(state: state, keepVisibleWhileSubmenuOpen: true)
        autoAmbientButton.state = state.autoAmbientSoundEnabled == true ? .on : .off
        setMenuCheckmark(
            autoAmbientButton,
            checked: state.autoAmbientSoundEnabled == true
        )
        autoAmbientButton.isEnabled = true
        autoAmbientSensitivityButton.title = "Sensitivity: \(state.autoAmbientSensitivity.label)"
        autoAmbientSensitivityButton.isEnabled = true
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

    private func notifyBatteryChanges(state: HeadphonesController.State) {
        guard state.deviceReachable, let level = state.batteryLevel else { return }

        defer {
            lastBatteryLevel = level
            lastBatteryCharging = state.batteryCharging
        }

        guard let previousLevel = lastBatteryLevel,
              let previousCharging = lastBatteryCharging else {
            return
        }

        if previousCharging != state.batteryCharging {
            let text = state.batteryCharging
                ? "Headphones are charging at \(level)%."
                : "Headphones stopped charging at \(level)%."
            deliverBatteryNotification(text)
        } else if previousLevel > 20 && level <= 20 {
            deliverBatteryNotification("Headphones battery is low (\(level)%).")
        }
    }

    private func deliverBatteryNotification(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "SonyConnect"
        content.body = text
        let request = UNNotificationRequest(
            identifier: "battery-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileLogger.shared.log("notifications", "battery notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateAmbientDetailVisibility(
        state: HeadphonesController.State,
        keepVisibleWhileSubmenuOpen: Bool
    ) {
        let ambientActive = state.ncMode == .ambient
        let keepVisible = keepVisibleWhileSubmenuOpen && noiseCancellingSubmenuIsOpen

        autoAmbientMenuItem.isHidden = !state.autoAmbientSoundAvailable && !keepVisible
        autoAmbientSensitivityMenuItem.isHidden =
            !(state.autoAmbientSoundAvailable && state.autoAmbientSoundEnabled == true) && !keepVisible
        autoAmbientMenuItem.isEnabled = true
        autoAmbientSensitivityMenuItem.isEnabled = true
        ambientLevelMenuItem.isHidden = !ambientActive && !keepVisible
        focusOnVoiceMenuItem.isHidden = !ambientActive && !keepVisible
        ambientLevelMenuItem.isEnabled = ambientActive
        focusOnVoiceButton.isEnabled = ambientActive
    }

    private func updateMultipointSubmenu(
        state: HeadphonesController.State
    ) {
        let supported =
            state.isWH1000XM6 &&
            (
                state.multipointToggleAvailable ||
                !state.connectedDevices.isEmpty
            )

        multipointMenuItem.isHidden = !supported
        multipointMenuItem.isEnabled = state.isConnected

        guard supported else {
            return
        }

        multipointManagerView.render(
            state: state
        )
    }

    private func updateDiscoveredFeatureMenus(state: HeadphonesController.State) {
        let live = state.isConnected
        wearingMenuItem.isHidden = !state.pauseWhenTakenOffAvailable
        wearingMenuItem.isEnabled = true
        pauseWhenTakenOffButton.state = state.pauseWhenTakenOff == true ? .on : .off
        setMenuCheckmark(
            pauseWhenTakenOffButton,
            checked: state.pauseWhenTakenOff == true
        )
        pauseWhenTakenOffButton.isEnabled = true

        listeningModesMenuItem.isHidden = !state.listeningModesAvailable
        listeningModesMenuItem.isEnabled = live
        let listeningMode = state.listeningMode ?? .standard
        listeningModesMenuItem.title = "Listening Mode: \(listeningMode.rawValue)"
        listeningModeView.render(state: state)

        let sensitivity = speakSensitivityLabel(state.speakToChatSensitivity)
        let timeout = speakTimeoutLabel(state.speakToChatTimeout)
        speakParentMenuItem.title = state.speakToChatEnabled == true
            ? "Speak-to-Chat: On"
            : "Speak-to-Chat: Off"
        speakSensitivityButton.title = "Sensitivity: \(sensitivity)"
        speakTimeoutButton.title = "Resume after: \(timeout)"
        speakSensitivityMenuItem.isEnabled = live && state.speakToChatConfigAvailable
        speakTimeoutMenuItem.isEnabled = live && state.speakToChatConfigAvailable
    }

    // MARK: - Menu actions

    @objc private func toggleTouchSensorButton(_ sender: NSButton) {
        guard controller.state.isConnected,
              controller.state.touchSensorEnabled != nil else {
            return
        }
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

    @objc private func togglePauseWhenTakenOff(_ sender: NSButton) {
        guard controller.state.isConnected,
              controller.state.pauseWhenTakenOff != nil else {
            return
        }
        controller.setPauseWhenTakenOff(sender.state == .on)
    }

    @objc private func setListeningMode(_ sender: NSButton) {
        let mode: HeadphonesController.ListeningMode
        switch sender.tag {
        case 1: mode = .backgroundMusic
        case 2: mode = .cinema
        default: mode = .standard
        }
        controller.setListeningMode(mode)
    }

    @objc private func setBgmRoomSize(_ sender: NSButton) {
        controller.setBgmRoomSize(UInt8(sender.tag))
    }

    private func bgmRoomName(_ value: UInt8?) -> String {
        switch value {
        case 0x00: return "My Room"
        case 0x01: return "Living Room"
        case 0x02: return "Cafe"
        default: return "My Room"
        }
    }

    private var listeningButtons: [Int: NSButton] = [:]

    private func listeningButton(for item: NSMenuItem, tag: Int) -> NSButton {
        if let button = listeningButtons[tag] { return button }
        let button = NSButton()
        button.tag = tag
        listeningButtons[tag] = button
        return button
    }

    private func speakSensitivityLabel(_ value: UInt8?) -> String {
        switch value {
        case 0: return "Low"
        case 1: return "Standard"
        case 2: return "High"
        case 3: return "Very High"
        case 4: return "Maximum"
        default: return "—"
        }
    }

    private func speakTimeoutLabel(_ value: UInt8?) -> String {
        switch value {
        case 0: return "Immediate"
        case 1: return "15 seconds"
        case 2: return "30 seconds"
        case 3: return "60 seconds"
        default: return "—"
        }
    }

    @objc private func cycleSpeakSensitivity(_ sender: NSMenuItem) {
        let current = controller.state.speakToChatSensitivity ?? 0
        let next = (current + 1) % 5
        controller.setSpeakToChatConfiguration(
            sensitivity: next,
            timeout: controller.state.speakToChatTimeout ?? 0
        )
    }

    @objc private func cycleSpeakTimeout(_ sender: NSMenuItem) {
        let current = controller.state.speakToChatTimeout ?? 0
        let next = (current + 1) % 4
        controller.setSpeakToChatConfiguration(
            sensitivity: controller.state.speakToChatSensitivity ?? 0,
            timeout: next
        )
    }

    @objc private func toggleFocusOnVoiceButton(_ sender: NSButton) {
        controller.setAmbientFocusOnVoice(sender.state == .on)
    }

    @objc private func toggleAutoAmbientButton(_ sender: NSButton) {
        guard controller.state.isConnected,
              controller.state.autoAmbientSoundAvailable else {
            return
        }
        controller.setAutoAmbientSound(sender.state == .on)
    }

    @objc private func cycleAutoAmbientSensitivity(_ sender: NSButton) {
        let values = HeadphonesController.AutoAmbientSensitivity.allCases
        let current = controller.state.autoAmbientSensitivity
        let nextIndex = (values.firstIndex(of: current).map { $0 + 1 } ?? 0) % values.count
        controller.setAutoAmbientSensitivity(values[nextIndex])
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
