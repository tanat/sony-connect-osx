import AppKit

final class MultipointMenuView: NSView {
    var onToggleMultipoint: ((Bool) -> Void)?
    var onPlayback: ((String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onSwap: ((String) -> Void)?
    var onTogglePairing: (() -> Void)?
    var onRefresh: (() -> Void)?

    private static let preferredWidth: CGFloat = 360

    private let rootStack = NSStackView()
    private let summaryButton = NSButton()
    private let multipointToggle = NSButton()
    private let devicesStack = NSStackView()
    private let pairingButton = NSButton()
    private let refreshButton = NSButton()

    private struct DeviceRow {
        let container: NSStackView
        let nameLabel: NSTextField
        let statusLabel: NSTextField
        let primaryButton: NSButton
        let secondaryButton: NSButton
    }

    private var deviceRows: [String: DeviceRow] = [:]
    private var deviceSignature = ""
    private var canToggleMultipoint = false
    private var detailViews: [NSView] = []
    private var isExpanded = true

    override init(frame frameRect: NSRect) {
        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Self.preferredWidth,
                height: 1
            )
        )

        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
               constant: 24
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -12
            ),
            rootStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: 8
            )
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )

        multipointToggle.setButtonType(.pushOnPushOff)
        multipointToggle.title = "Multipoint"
        multipointToggle.isBordered = false
        multipointToggle.imagePosition = .imageLeading
        multipointToggle.imageScaling = .scaleProportionallyDown
        multipointToggle.contentTintColor = .labelColor
        multipointToggle.image = menuCheckmarkImage(checked: false)
        multipointToggle.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )
        multipointToggle.target = self
        multipointToggle.action =
            #selector(toggleMultipoint(_:))

        header.addArrangedSubview(multipointToggle)
        header.addArrangedSubview(spacer)

        summaryButton.setButtonType(.momentaryPushIn)
        summaryButton.isBordered = false
        summaryButton.imagePosition = .imageTrailing
        summaryButton.imageScaling = .scaleProportionallyDown
        summaryButton.alignment = .right
        summaryButton.contentTintColor = .secondaryLabelColor
        summaryButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        summaryButton.target = self
        summaryButton.action = #selector(toggleExpanded)
        summaryButton.setContentHuggingPriority(.required, for: .horizontal)
        summaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addArrangedSubview(summaryButton)

        rootStack.addArrangedSubview(header)

        header.leadingAnchor.constraint(
            equalTo: rootStack.leadingAnchor,
            constant: 0
        ).isActive = true
        header.trailingAnchor.constraint(
            equalTo: rootStack.trailingAnchor
        ).isActive = true

        addSeparator()

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8

        rootStack.addArrangedSubview(devicesStack)
        detailViews.append(devicesStack)

        devicesStack.widthAnchor.constraint(
            equalTo: rootStack.widthAnchor
        ).isActive = true

        addSeparator()

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        pairingButton.title = "Connect to New Device…"
        pairingButton.bezelStyle = .rounded
        pairingButton.controlSize = .small
        pairingButton.target = self
        pairingButton.action =
            #selector(togglePairing(_:))

        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action =
            #selector(refresh(_:))

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )

        footer.addArrangedSubview(pairingButton)
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(refreshButton)

        rootStack.addArrangedSubview(footer)
        detailViews.append(footer)

        footer.widthAnchor.constraint(
            equalTo: rootStack.widthAnchor
        ).isActive = true

        updateDisclosureAppearance()
    }

    private func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator

        rootStack.addArrangedSubview(separator)
        detailViews.append(separator)

        separator.widthAnchor.constraint(
            equalTo: rootStack.widthAnchor
        ).isActive = true

        separator.heightAnchor.constraint(
            equalToConstant: 1
        ).isActive = true
    }

    func render(state: HeadphonesController.State) {
        let connected = state.connectedDevices
            .filter { $0.isConnected }

        if state.multipointEnabled == false {
            summaryButton.title = "Off"
        } else if state.connectedDevicesAreLive {
            summaryButton.title =
                "\(connected.count) Connected"
        } else {
            summaryButton.title = "Last Known"
        }

        let displayedMultipoint =
            state.pendingMultipointEnabled ??
            state.multipointEnabled

        multipointToggle.state =
            displayedMultipoint == true
                ? .on
                : .off
        multipointToggle.image = menuCheckmarkImage(
            checked: displayedMultipoint == true
        )

        for view in detailViews {
            view.isHidden = !isExpanded
        }

        canToggleMultipoint =
            state.isConnected &&
            state.multipointToggleAvailable &&
            state.multipointEnabled != nil &&
            state.pendingMultipointEnabled == nil &&
            !state.multipointSwapInProgress
        multipointToggle.isEnabled = true

        let devices = state.connectedDevices.sorted {
            if $0.isConnected != $1.isConnected {
                return $0.isConnected && !$1.isConnected
            }

            if $0.connectionSlot != $1.connectionSlot {
                return ($0.connectionSlot ?? Int.max) <
                    ($1.connectionSlot ?? Int.max)
            }

            return $0.name.localizedCaseInsensitiveCompare(
                $1.name
            ) == .orderedAscending
        }

        let signature = devices.map {
            "\($0.address)|\($0.name)"
        }.joined(separator: ";")

        if signature != deviceSignature {
            deviceSignature = signature
            rebuildDeviceRows(devices)
        }

        let localAddress =
            state.localBluetoothAddress?
                .replacingOccurrences(of: "-", with: ":")
                .uppercased()

        let thisMacIsConnected: Bool

        if let localAddress {
            thisMacIsConnected = connected.contains {
                normalize($0.address) == localAddress
            }
        } else {
            thisMacIsConnected = false
        }

        for device in devices {
            guard let row = deviceRows[device.address] else {
                continue
            }

            let isPlayback =
                device.isConnected &&
                device.connectionSlot ==
                    state.playbackDeviceSlot

            row.nameLabel.stringValue = device.name

            if device.isConnected {
                var status = ["Connected"]

                if isPlayback {
                    status.append("Playback")
                }

                row.statusLabel.stringValue =
                    status.joined(separator: " · ")
            } else {
                row.statusLabel.stringValue = "Known"
            }

            if device.isConnected {
                row.primaryButton.isHidden = false
                row.secondaryButton.isHidden = false

                row.primaryButton.title =
                    isPlayback ? "Playing" : "Play"

                row.primaryButton.identifier =
                    NSUserInterfaceItemIdentifier(
                        "play|\(device.address)"
                    )

                row.primaryButton.isEnabled =
                    state.isConnected &&
                    !isPlayback &&
                    state.multipointEnabled != false &&
                    !state.multipointSwapInProgress

                row.secondaryButton.title = "Disconnect"

                row.secondaryButton.identifier =
                    NSUserInterfaceItemIdentifier(
                        "disconnect|\(device.address)"
                    )

                row.secondaryButton.isEnabled =
                    state.isConnected &&
                    state.connectedDevicesAreLive &&
                    state.multipointDeviceManagementAvailable &&
                    !state.multipointSwapInProgress
            } else {
                row.secondaryButton.isHidden = true
                row.primaryButton.isHidden = false

                if connected.count < 2 {
                    row.primaryButton.title = state.multipointSwapInProgress
                        ? "Swapping…"
                        : "Connect"

                    row.primaryButton.identifier =
                        NSUserInterfaceItemIdentifier(
                            "connect|\(device.address)"
                        )

                    row.primaryButton.isEnabled =
                        state.isConnected &&
                        state.connectedDevicesAreLive &&
                        state.multipointDeviceManagementAvailable &&
                        state.multipointEnabled != false &&
                        !state.multipointSwapInProgress
                } else {
                    row.primaryButton.title = state.multipointSwapInProgress
                        ? "Swapping…"
                        : "Swap In"

                    row.primaryButton.identifier =
                        NSUserInterfaceItemIdentifier(
                            "swap|\(device.address)"
                        )

                    row.primaryButton.isEnabled =
                        state.isConnected &&
                        state.connectedDevicesAreLive &&
                        state.multipointDeviceManagementAvailable &&
                        state.multipointEnabled == true &&
                        thisMacIsConnected &&
                        !state.multipointSwapInProgress
                }
            }
        }

        pairingButton.title =
            state.pairingMode == true
                ? "Stop Pairing Mode"
                : "Connect to New Device…"

        // Starting pairing with both slots occupied caused the
        // XM6 control channel to reset during hardware testing.
        // Stopping an already-active pairing session is always allowed.
        let canStartPairing =
            connected.count < 2

        pairingButton.isEnabled =
            state.isConnected &&
            state.pairingModeAvailable &&
            state.pendingPairingMode == nil &&
            !state.multipointSwapInProgress &&
            (
                state.pairingMode == true ||
                canStartPairing
            )

        pairingButton.toolTip =
            !canStartPairing &&
            state.pairingMode != true
                ? "Disconnect one device before pairing a new device."
                : nil

        refreshButton.isEnabled =
            state.isConnected &&
            !state.multipointSwapInProgress

        updateSize()
    }

    private func rebuildDeviceRows(
        _ devices: [HeadphonesController.ConnectedDevice]
    ) {
        for view in devicesStack.arrangedSubviews {
            devicesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        deviceRows.removeAll()

        for device in devices {
            let container = NSStackView()
            container.orientation = .horizontal
            container.alignment = .centerY
            container.spacing = 8

            let textStack = NSStackView()
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 1

            let nameLabel = NSTextField(
                labelWithString: device.name
            )
            nameLabel.font = .systemFont(
                ofSize: NSFont.systemFontSize,
                weight: .medium
            )

            let statusLabel = NSTextField(
                labelWithString: ""
            )
            statusLabel.font = .systemFont(
                ofSize: NSFont.smallSystemFontSize
            )
            statusLabel.textColor = .secondaryLabelColor

            textStack.addArrangedSubview(nameLabel)
            textStack.addArrangedSubview(statusLabel)

            let spacer = NSView()
            spacer.setContentHuggingPriority(
                .defaultLow,
                for: .horizontal
            )

            let primary = actionButton()
            let secondary = actionButton()

            container.addArrangedSubview(textStack)
            container.addArrangedSubview(spacer)
            container.addArrangedSubview(primary)
            container.addArrangedSubview(secondary)

            devicesStack.addArrangedSubview(container)

            container.widthAnchor.constraint(
                equalTo: devicesStack.widthAnchor
            ).isActive = true

            deviceRows[device.address] = DeviceRow(
                container: container,
                nameLabel: nameLabel,
                statusLabel: statusLabel,
                primaryButton: primary,
                secondaryButton: secondary
            )
        }
    }

    private func actionButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(deviceAction(_:))
        return button
    }

    private func normalize(_ address: String) -> String {
        address
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private func updateSize() {
        layoutSubtreeIfNeeded()

        let height =
            max(1, rootStack.fittingSize.height + 16)

        frame.size = NSSize(
            width: Self.preferredWidth,
            height: height
        )

        invalidateIntrinsicContentSize()
    }

    private func updateDisclosureAppearance() {
        summaryButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "Collapse Multipoint" : "Expand Multipoint"
        )
        summaryButton.toolTip = isExpanded ? "Collapse Multipoint" : "Expand Multipoint"
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        for view in detailViews {
            view.isHidden = !isExpanded
        }
        updateDisclosureAppearance()
        updateSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.preferredWidth,
            height: max(
                1,
                rootStack.fittingSize.height + 16
            )
        )
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

    @objc private func toggleMultipoint(
        _ sender: NSButton
    ) {
        guard canToggleMultipoint else {
            return
        }
        onToggleMultipoint?(
            sender.state == .on
        )
    }

    @objc private func togglePairing(
        _ sender: NSButton
    ) {
        onTogglePairing?()
    }

    @objc private func refresh(
        _ sender: NSButton
    ) {
        onRefresh?()
    }

    @objc private func deviceAction(
        _ sender: NSButton
    ) {
        guard let raw =
            sender.identifier?.rawValue else {
            return
        }

        let pieces = raw.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        guard pieces.count == 2 else {
            return
        }

        let action = String(pieces[0])
        let address = String(pieces[1])

        switch action {
        case "play":
            onPlayback?(address)

        case "connect":
            onConnect?(address)

        case "disconnect":
            onDisconnect?(address)

        case "swap":
            onSwap?(address)

        default:
            return
        }
    }
}
