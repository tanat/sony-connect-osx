import AppKit

// Custom menu-item view: a row of vertical band sliders (graphic EQ)
// with frequency labels underneath. Preset selection lives in a native
// submenu instead (an NSPopUpButton doesn't receive clicks reliably
// inside a status-bar menu's custom view).
final class EqualizerView: NSView {
    var onBandsChanged: (([Int]) -> Void)?

    private var sliders: [NSSlider] = []
    private var labels: [NSTextField] = []

    private let hInset: CGFloat = 16
    private let topPad: CGFloat = 8
    private let sliderHeight: CGFloat = 58
    private let labelHeight: CGFloat = 13
    private let labelGap: CGFloat = 2
    private let bottomPad: CGFloat = 6
    private let sliderWidth: CGFloat = 16

    init() {
        let h = 8 + 58 + 2 + 13 + 6
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(h)))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setBands(_ bands: [Int]) {
        if sliders.count != bands.count {
            rebuild(count: bands.count)
        }
        for (i, value) in bands.enumerated() {
            sliders[i].integerValue = value
        }
    }

    // MARK: - Building

    private func rebuild(count: Int) {
        (sliders + labels).forEach { $0.removeFromSuperview() }
        sliders.removeAll()
        labels.removeAll()
        let names = Self.bandLabels(count: count)
        for i in 0..<count {
            let slider = makeBandSlider()
            addSubview(slider)
            sliders.append(slider)

            let label = makeLabel(i < names.count ? names[i] : "\(i + 1)")
            addSubview(label)
            labels.append(label)
        }
        needsLayout = true
    }

    // Sony 5-band layout + Clear Bass when 6 bands are reported.
    private static func bandLabels(count: Int) -> [String] {
        switch count {
        case 6: return ["400", "1k", "2.5k", "6.3k", "16k", "CB"]
        case 5: return ["400", "1k", "2.5k", "6.3k", "16k"]
        default: return (1...max(count, 1)).map { "\($0)" }
        }
    }

    private func makeBandSlider() -> NSSlider {
        let s = NSSlider()
        s.isVertical = true
        s.minValue = 0
        s.maxValue = 20            // Sony EQ bands: 0…20 (10 = flat)
        s.isContinuous = false     // commit on mouse-up, don't flood RFCOMM
        s.controlSize = .mini
        s.target = self
        s.action = #selector(bandChanged)
        return s
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 9)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        return l
    }

    @objc private func bandChanged() {
        onBandsChanged?(sliders.map { $0.integerValue })
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard !sliders.isEmpty else { return }
        let area = bounds.width - 2 * hInset
        let slot = area / CGFloat(sliders.count)
        let sliderY = bottomPad + labelHeight + labelGap
        for (i, slider) in sliders.enumerated() {
            let centerX = hInset + slot * (CGFloat(i) + 0.5)
            slider.frame = NSRect(x: centerX - sliderWidth / 2, y: sliderY,
                                  width: sliderWidth, height: sliderHeight)
            labels[i].frame = NSRect(x: centerX - slot / 2, y: bottomPad,
                                     width: slot, height: labelHeight)
        }
    }
}
