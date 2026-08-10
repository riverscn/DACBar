import AppKit

/// The connector-and-note pairing from the app icon, as a glyph the app can draw
/// wherever it identifies the device — so the menu bar, the panel header, the
/// Dock and the Login Items row all read as one app.
///
/// Composed by hand rather than taken from a single SF Symbol because no symbol
/// carries both meanings. The proportions mirror `tools/make-icon.swift` — note
/// at 0.536 of the connector's height, tops level, gap 0.136 of that height —
/// and are restated here rather than shared because that script runs standalone
/// at design time and this runs in the app.
enum DeviceGlyph {

    private static let noteRatio: CGFloat = 0.536
    private static let gapRatio: CGFloat = 0.136

    /// The status bar allows about 18 points; the headroom keeps the note's flag
    /// clear of the menu bar's edge.
    static let menuBar: NSImage = build(connectorHeight: 16)

    /// Shown when the dongle is unplugged.
    ///
    /// The fade is baked into the image's alpha rather than applied with
    /// `.opacity` on the label: a template image is drawn from its alpha alone,
    /// so this survives whatever the status bar does with the view.
    static let menuBarInactive: NSImage = build(connectorHeight: 16, alpha: 0.35)

    static func menuBar(present: Bool) -> NSImage {
        present ? menuBar : menuBarInactive
    }

    /// Matches the point size the panel header previously gave the lone symbol.
    static let header: NSImage = build(connectorHeight: 15)

    /// The symbol's opaque bounds, in its own coordinate space with y up.
    ///
    /// SF Symbols pad unevenly, so laying the two out by their bounding boxes
    /// puts their visible tops at different heights.
    private static func inkBounds(of image: NSImage) -> CGRect {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return .zero }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return .zero }
        let stride = rep.bytesPerRow, samples = rep.samplesPerPixel
        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            for column in 0..<width where data[row * stride + column * samples + 3] > 5 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row);    maxY = max(maxY, row)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    private static func symbol(_ name: String, _ weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 256, weight: weight))
    }

    private static func build(connectorHeight: CGFloat, alpha: CGFloat = 1) -> NSImage {
        guard let connector = symbol("cable.connector", .medium),
              let note = symbol("music.note", .semibold) else {
            // Falling back to the plain symbol keeps a menu bar item on screen;
            // an empty image would leave nothing to click.
            return NSImage(systemSymbolName: "cable.connector",
                           accessibilityDescription: "USB DAC") ?? NSImage()
        }
        let connectorInk = inkBounds(of: connector)
        let noteInk = inkBounds(of: note)

        let connectorFit = connectorHeight / connectorInk.height
        let noteFit = connectorHeight * noteRatio / noteInk.height
        let connectorWidth = connectorInk.width * connectorFit
        let noteWidth = noteInk.width * noteFit
        let gap = connectorHeight * gapRatio

        let size = NSSize(width: connectorWidth + gap + noteWidth, height: connectorHeight)
        let canvas = NSImage(size: size)
        canvas.lockFocus()

        func place(_ image: NSImage, _ ink: CGRect, _ fit: CGFloat, x: CGFloat) {
            image.draw(in: NSRect(x: x - ink.minX * fit,
                                  y: size.height - (ink.minY + ink.height) * fit,
                                  width: image.size.width * fit,
                                  height: image.size.height * fit),
                       from: .zero, operation: .sourceOver, fraction: alpha)
        }
        place(connector, connectorInk, connectorFit, x: 0)
        place(note, noteInk, noteFit, x: connectorWidth + gap)

        canvas.unlockFocus()

        // Template images are drawn from their alpha alone, which is what lets
        // the menu bar invert them for light and dark and dim them when the app
        // is not frontmost.
        canvas.isTemplate = true
        return canvas
    }
}
