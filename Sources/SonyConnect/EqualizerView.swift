import AppKit

// Custom menu-item view containing the graphic equalizer.
// Legacy Sony devices retain their existing 0...20 representation.
// 10-band v2 devices such as WH-1000XM6 use the Sony -6...+6 scale.
final class EqualizerView: NSView {
    var onBandsChanged: (([Int]) -> Void)?

    private var sliders: [NSSlider] = []
    private var labels: [NSTextField] = []
    private var valueLabels: [NSTextField] = []
    private var axisLabels: [NSTextField] = []

    private let axisInset: CGFloat = 20
    private let hInset: CGFloat = 16
    private let sliderHeight: CGFloat = 78
    private let labelHeight: CGFloat = 14
    private let valueHeight: CGFloat = 14
    private let labelGap: CGFloat = 3
    private let bottomPad: CGFloat = 8
    private let sliderWidth: CGFloat = 16

    init() {
        let h = 8 + 78 + 3 + 14 + 14 + 8
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: CGFloat(h)))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("not implemented")
    }

    func setBands(_ bands: [Int]) {
        if sliders.count != bands.count {
            rebuild(count: bands.count)
        }

        for (i, value) in bands.enumerated() where i < sliders.count {
            sliders[i].integerValue = value
            if i < valueLabels.count {
                valueLabels[i].stringValue = Self.displayValue(value)
            }
        }
    }

    // MARK: - Building

    private func rebuild(count: Int) {
        (sliders + labels + valueLabels + axisLabels).forEach { $0.removeFromSuperview() }

        sliders.removeAll()
        labels.removeAll()
        valueLabels.removeAll()
        axisLabels.removeAll()

        let isTenBand = count == 10

        addAxisLabels(isTenBand: isTenBand)

        let names = Self.bandLabels(count: count)

        for i in 0..<count {
            let slider = makeBandSlider(isTenBand: isTenBand)
            addSubview(slider)
            sliders.append(slider)

            let valueLabel = makeLabel("0")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            valueLabel.textColor = .labelColor
            addSubview(valueLabel)
            valueLabels.append(valueLabel)

            let label = makeLabel(i < names.count ? names[i] : "\(i + 1)")
            addSubview(label)
            labels.append(label)
        }

        needsLayout = true
    }

    private func addAxisLabels(isTenBand: Bool) {
        let sliderY = bottomPad + labelHeight + valueHeight + labelGap

        let values: [(String, CGFloat)] = isTenBand
            ? [("+6", 1.0), ("0", 0.5), ("-6", 0.0)]
            : [("+10", 1.0), ("0", 0.5), ("-10", 0.0)]

        for (value, yFraction) in values {
            let label = makeLabel(value)
            label.alignment = .left

            let y = sliderY
                + yFraction * sliderHeight
                - labelHeight / 2

            label.frame = NSRect(
                x: 2,
                y: y,
                width: axisInset - 4,
                height: labelHeight
            )

            label.autoresizingMask = [.maxXMargin]
            addSubview(label)
            axisLabels.append(label)
        }
    }

    private static func bandLabels(count: Int) -> [String] {
        switch count {
        case 10:
            return ["31", "63", "125", "250", "500",
                    "1k", "2k", "4k", "8k", "16k"]

        case 6:
            return ["400", "1k", "2.5k", "6.3k", "16k", "CB"]

        case 5:
            return ["400", "1k", "2.5k", "6.3k", "16k"]

        default:
            return (1...max(count, 1)).map { "\($0)" }
        }
    }

    private func makeBandSlider(isTenBand: Bool) -> NSSlider {
        let slider = ScrollableSlider()
        slider.isVertical = true

        if isTenBand {
            slider.minValue = -6
            slider.maxValue = 6
            slider.numberOfTickMarks = 13
        } else {
            slider.minValue = 0
            slider.maxValue = 20
            slider.numberOfTickMarks = 21
        }

        slider.isContinuous = false
        slider.controlSize = .mini
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .trailing
        slider.target = self
        slider.action = #selector(bandChanged)

        return slider
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }

    @objc private func bandChanged() {
        let values = sliders.map { $0.integerValue }

        for (i, value) in values.enumerated() where i < valueLabels.count {
            valueLabels[i].stringValue = Self.displayValue(value)
        }

        onBandsChanged?(values)
    }

    private static func displayValue(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        guard !sliders.isEmpty else { return }

        let area = bounds.width - axisInset - 2 * hInset
        let slot = area / CGFloat(sliders.count)
        let sliderY = bottomPad + labelHeight + valueHeight + labelGap

        for (i, slider) in sliders.enumerated() {
            let centerX = axisInset + hInset + slot * (CGFloat(i) + 0.5)

            slider.frame = NSRect(
                x: centerX - sliderWidth / 2,
                y: sliderY,
                width: sliderWidth,
                height: sliderHeight
            )

            valueLabels[i].frame = NSRect(
                x: centerX - slot / 2,
                y: bottomPad + labelHeight,
                width: slot,
                height: valueHeight
            )

            labels[i].frame = NSRect(
                x: centerX - slot / 2,
                y: bottomPad,
                width: slot,
                height: labelHeight
            )
        }
    }
}
