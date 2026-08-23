import AppKit

final class ListeningModeMenuView: NSView {
    var onModeChanged: ((HeadphonesController.ListeningMode) -> Void)?
    var onRoomChanged: ((UInt8) -> Void)?

    private static let preferredWidth: CGFloat = 230
    private let rootStack = NSStackView()
    private let headerButton = NSButton()
    private let detailsStack = NSStackView()
    private let standardButton = NSButton()
    private let backgroundButton = NSButton()
    private let cinemaButton = NSButton()
    private let roomOptionsStack = NSStackView()
    private let myRoomButton = NSButton()
    private let livingRoomButton = NSButton()
    private let cafeButton = NSButton()

    private var expanded = true
    private var showsHeader = true
    private var currentMode: HeadphonesController.ListeningMode = .standard
    private var currentRoom: UInt8 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 1))
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 4
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        ])

        configureHeader()
        configureRadio(standardButton, title: "Standard", tag: 0)
        configureRadio(backgroundButton, title: "Background Music", tag: 1)
        configureRadio(cinemaButton, title: "Cinema", tag: 2)

        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 6
        detailsStack.addArrangedSubview(standardButton)
        detailsStack.addArrangedSubview(backgroundButton)

        roomOptionsStack.orientation = .vertical
        roomOptionsStack.alignment = .leading
        roomOptionsStack.spacing = 3
        roomOptionsStack.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
        configureRadio(myRoomButton, title: "My Room", tag: 0, action: #selector(selectRoom(_:)))
        configureRadio(livingRoomButton, title: "Living Room", tag: 1, action: #selector(selectRoom(_:)))
        configureRadio(cafeButton, title: "Cafe", tag: 2, action: #selector(selectRoom(_:)))
        roomOptionsStack.addArrangedSubview(myRoomButton)
        roomOptionsStack.addArrangedSubview(livingRoomButton)
        roomOptionsStack.addArrangedSubview(cafeButton)
        detailsStack.addArrangedSubview(roomOptionsStack)
        detailsStack.addArrangedSubview(cinemaButton)

        rootStack.addArrangedSubview(headerButton)
        rootStack.addArrangedSubview(detailsStack)
        updateAppearance()
    }

    private func configureHeader() {
        configureHeaderButton(headerButton, action: #selector(toggleExpanded))
        headerButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        headerButton.setContentHuggingPriority(.required, for: .horizontal)
        headerButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureHeaderButton(_ button: NSButton, action: Selector) {
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.autoresizingMask = [.width]
        button.frame = NSRect(x: 0, y: 0, width: Self.preferredWidth - 42, height: 24)
    }

    private func configureRadio(
        _ button: NSButton,
        title: String,
        tag: Int,
        action: Selector = #selector(selectMode(_:))
    ) {
        button.setButtonType(.radio)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.title = title
        button.tag = tag
        button.target = self
        button.action = action
        button.frame = NSRect(x: 0, y: 0, width: Self.preferredWidth - 42, height: 24)
        button.autoresizingMask = [.width]
    }

    func render(state: HeadphonesController.State) {
        currentMode = state.listeningMode ?? .standard
        currentRoom = state.bgmRoomSize ?? 0
        headerButton.title = "Listening Mode: \(currentMode.rawValue)"
        headerButton.isEnabled = true
        standardButton.state = currentMode == .standard ? .on : .off
        backgroundButton.state = currentMode == .backgroundMusic ? .on : .off
        cinemaButton.state = currentMode == .cinema ? .on : .off
        myRoomButton.state = currentRoom == 0 ? .on : .off
        livingRoomButton.state = currentRoom == 1 ? .on : .off
        cafeButton.state = currentRoom == 2 ? .on : .off
        let controlsEnabled = state.isConnected
        standardButton.isEnabled = controlsEnabled
        backgroundButton.isEnabled = controlsEnabled
        cinemaButton.isEnabled = controlsEnabled
        myRoomButton.isEnabled = controlsEnabled
        livingRoomButton.isEnabled = controlsEnabled
        cafeButton.isEnabled = controlsEnabled
        roomOptionsStack.isHidden = currentMode != .backgroundMusic
        updateAppearance()
        updateSize()
    }

    func setShowsHeader(_ showsHeader: Bool) {
        self.showsHeader = showsHeader
        headerButton.isHidden = !showsHeader
        updateSize()
    }

    private func updateAppearance() {
        headerButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse Listening Mode" : "Expand Listening Mode"
        )
        detailsStack.isHidden = !expanded
        headerButton.isHidden = !showsHeader
    }

    private func roomName(_ value: UInt8) -> String {
        switch value {
        case 1: return "Living Room"
        case 2: return "Cafe"
        default: return "My Room"
        }
    }

    private func updateSize() {
        layoutSubtreeIfNeeded()
        frame.size = NSSize(width: Self.preferredWidth, height: max(1, rootStack.fittingSize.height + 16))
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: max(1, rootStack.fittingSize.height + 16))
    }

    @objc private func toggleExpanded() {
        expanded.toggle()
        updateAppearance()
        updateSize()
    }

    @objc private func selectMode(_ sender: NSButton) {
        let mode: HeadphonesController.ListeningMode
        switch sender.tag {
        case 1: mode = .backgroundMusic
        case 2: mode = .cinema
        default: mode = .standard
        }
        currentMode = mode
        onModeChanged?(mode)
        render(state: makeStateForRender())
    }

    @objc private func selectRoom(_ sender: NSButton) {
        currentRoom = UInt8(sender.tag)
        onRoomChanged?(currentRoom)
        updateSize()
    }

    private func makeStateForRender() -> HeadphonesController.State {
        var state = HeadphonesController.State()
        state.listeningMode = currentMode
        state.bgmRoomSize = currentRoom
        return state
    }
}
