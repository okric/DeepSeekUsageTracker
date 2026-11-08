import AppKit

final class StatusBarView: NSView {
    var onOpenMenu: (() -> Void)?

    private var primaryText = "—"
    private var secondaryText = ""
    private var accentColor: NSColor = .systemGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("DeepSeek usage")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(primary: String, secondary: String, accent: NSColor) {
        primaryText = primary
        secondaryText = secondary
        accentColor = accent
        setAccessibilityValue(secondary.isEmpty ? primary : "\(primary), \(secondary)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let dotSize: CGFloat = 5
        let dotX: CGFloat = 2
        let dotY = bounds.midY - dotSize / 2
        accentColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        ).fill()

        let textX = dotX + dotSize + 4
        let primaryFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let secondaryFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .font: primaryFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: secondaryFont,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82),
        ]

        let primarySize = (primaryText as NSString).size(withAttributes: primaryAttributes)
        let primaryY = bounds.height - primarySize.height
        (primaryText as NSString).draw(
            at: NSPoint(x: textX, y: primaryY),
            withAttributes: primaryAttributes)

        if !secondaryText.isEmpty {
            (secondaryText as NSString).draw(
                at: NSPoint(x: textX, y: 0),
                withAttributes: secondaryAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onOpenMenu?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onOpenMenu?()
    }
}
