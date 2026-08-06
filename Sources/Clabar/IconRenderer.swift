import AppKit

// Derived from Blimp-Labs/claude-usage-bar (BSD-2-Clause); generalized to a
// variable number of bar rows.

private let labelWidth: CGFloat = 14
private let barWidth: CGFloat = 24
private let rowGap: CGFloat = 2
private let labelGap: CGFloat = 2
private let cornerRadius: CGFloat = 2
private let logoSize: CGFloat = 12
private let logoGap: CGFloat = 2
private let iconHeight: CGFloat = 18
private let fontSize: CGFloat = 8

struct IconRow {
    let label: String
    let pct: Double?  // nil = unauthenticated (dashed)
}

func renderIcon(rows: [IconRow], showLogo: Bool = true) -> NSImage {
    let rowCount = max(rows.count, 1)
    let barHeight: CGFloat = rowCount >= 3 ? 4 : 5
    let offset = showLogo ? logoSize + logoGap : 0
    let width = offset + labelWidth + labelGap + barWidth + 2
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]

    let image = NSImage(size: NSSize(width: width, height: iconHeight), flipped: true) { _ in
        if showLogo {
            drawClaudeLogo(x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)
        }
        let totalHeight = CGFloat(rowCount) * barHeight + CGFloat(rowCount - 1) * rowGap
        var y = (iconHeight - totalHeight) / 2
        let barX = offset + labelWidth + labelGap

        for row in rows {
            let text = NSAttributedString(string: row.label, attributes: attrs)
            let size = text.size()
            text.draw(at: NSPoint(x: offset + labelWidth - size.width, y: y + (barHeight - size.height) / 2))
            if let pct = row.pct {
                drawBar(x: barX, y: y, width: barWidth, height: barHeight, pct: pct)
            } else {
                drawDashedBar(x: barX, y: y, width: barWidth, height: barHeight)
            }
            y += barHeight + rowGap
        }
        return true
    }
    image.isTemplate = true
    return image
}

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, pct: Double) {
    let bgPath = NSBezierPath(
        roundedRect: NSRect(x: x, y: y, width: width, height: height),
        xRadius: cornerRadius, yRadius: cornerRadius
    )
    NSColor.black.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clamped = max(0, min(1, pct))
    if clamped > 0 {
        let fillPath = NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width * clamped, height: height),
            xRadius: cornerRadius, yRadius: cornerRadius
        )
        NSColor.black.setFill()
        fillPath.fill()
    }
}

private func drawDashedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    let path = NSBezierPath(
        roundedRect: NSRect(x: x, y: y, width: width, height: height),
        xRadius: cornerRadius, yRadius: cornerRadius
    )
    NSColor.black.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    path.setLineDash([2, 2], count: 2, phase: 0)
    path.stroke()
}

private let claudeLogoImage: NSImage? = {
    guard let url = Bundle.module.url(forResource: "claude-logo", withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
}()

private func drawClaudeLogo(x: CGFloat, y: CGFloat, size: CGFloat) {
    claudeLogoImage?.draw(in: NSRect(x: x, y: y, width: size, height: size))
}
