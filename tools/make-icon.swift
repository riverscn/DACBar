#!/usr/bin/env swift
//
// Generates DACBar/Resources/AppIcon.icon — an Icon Composer document.
//
//     swift tools/make-icon.swift
//
// The .icon package is a directory holding a JSON manifest plus layer art. It
// replaces the flat .icns: macOS 26 renders a legacy .icns shrunk inside a grey
// system plate, whereas a .icon fills the frame and gets the dark and tinted
// variants generated for free.
//
// build.sh compiles this with actool, which emits both Assets.car (macOS 26)
// and a fallback AppIcon.icns (earlier releases) — so nothing here produces an
// .icns directly.
//
import AppKit
import Foundation

// Layer art is drawn on a 1024×1024 canvas with **no background and no rounded
// corners**: the manifest's `fill` supplies the backdrop and the system applies
// the squircle. Baking either into the art is what produces the nested-plate
// look this format exists to avoid.
let canvas: CGFloat = 1024

/// Where an element sits vertically.
enum Placement {
    /// Ink centre at this fraction of the canvas height.
    case center(y: CGFloat)
    /// Ink top edge level with that element's, whatever size either one is.
    /// Stated as a relationship rather than a computed constant so that changing
    /// a scale cannot quietly break the alignment.
    case topAlignedWith(String)
}

/// One SF Symbol rendered onto its own full-canvas layer.
///
/// Position is baked into each layer's artwork rather than expressed as the
/// manifest's `position.translation-in-points`, so composition stays in this
/// file — reachable from a diff — instead of splitting across two places.
///
/// Every measurement below is of the **ink**, not of the symbol's bounding box:
/// SF Symbols carry uneven padding, so box-relative numbers do not correspond to
/// what the eye lines up on.
struct Element {
    /// Layer art filename, and the `image-name` the manifest refers to.
    let file: String
    let symbol: String
    let weight: NSFont.Weight
    /// Fraction of the canvas spanned by the ink's longest side. The art runs
    /// edge to edge — there is no inset plate to sit inside — so this measures
    /// against the whole canvas, and the corners the system rounds off are what
    /// keep it from looking cramped.
    let scale: CGFloat
    /// Ink centre, as a fraction of the canvas width.
    let x: CGFloat
    let placement: Placement
}

/// The connector says "USB dongle", the note says "audio".
///
/// The connector stays centred and full size — it is the subject, and moving it
/// aside to make room for the note left the icon looking off balance. The note
/// sits beside it, tops level, close enough to read as a pair but not
/// overlapping: at Dock sizes two overlapping shapes merge into one smudge.
///
/// The connector is listed first because the note's placement refers to it.
let elements = [
    Element(file: "connector.png", symbol: "cable.connector", weight: .medium,
            scale: 0.56, x: 0.50, placement: .center(y: 0.50)),
    Element(file: "note.png", symbol: "music.note", weight: .semibold,
            scale: 0.30, x: 0.75, placement: .topAlignedWith("connector.png")),
]

/// Shifts the whole composition sideways, as a fraction of the canvas.
///
/// The note hangs off the right, so the pair's visual centre of mass sits right
/// of the canvas centre even with the connector on the grid centre. Nudging
/// everything left compensates. Applied to the group rather than to each element
/// so the spacing between them stays put.
///
/// Set so the pair's alpha-weighted centroid lands on the canvas centre. Going
/// by the combined bounding box instead would ask for about −0.13, which
/// overshoots badly: a bounding box counts the note's thin stem and flag as
/// weighing the same as the connector's solid body, when the eye does not.
let groupOffsetX: CGFloat = -0.067

/// Backdrop colour, seeded to `automatic-gradient` — Icon Composer derives the
/// vertical ramp itself rather than taking two stops.
let fill = (red: 0.22, green: 0.33, blue: 0.86)

// MARK: - Layer art

/// A bitmap context of exactly the requested pixel size.
///
/// Deliberately not NSImage.lockFocus, which follows the screen's backing scale
/// and so silently yields a 2048px bitmap on a Retina Mac. Icon Composer places
/// layer art on a 1024 canvas pixel for pixel, and renders such a layer at
/// double size — a discrepancy no amount of adjusting `scale` explains.
func bitmap(_ width: Int, _ height: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write(Data("创建位图失败\n".utf8))
        exit(1)
    }
    return (rep, context)
}

/// The image's opaque bounds, in its own coordinate space with y up.
func inkBounds(of image: NSImage) -> CGRect {
    let width = Int(image.size.width.rounded())
    let height = Int(image.size.height.rounded())
    let (rep, context) = bitmap(width, height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.bitmapData else { return .zero }
    let stride = rep.bytesPerRow
    let samples = rep.samplesPerPixel
    var minX = width, maxX = -1, minY = height, maxY = -1
    for row in 0..<height {
        for column in 0..<width where data[row * stride + column * samples + 3] > 5 {
            minX = min(minX, column); maxX = max(maxX, column)
            minY = min(minY, row);    maxY = max(maxY, row)
        }
    }
    guard maxX >= minX else { return .zero }

    // Bitmap rows count down from the top; AppKit drawing counts up from the
    // bottom. Flip so the caller can position with the same maths it draws with.
    return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

/// Draws one element, returning its artwork and where its ink top landed so a
/// later element can line up with it.
func draw(_ element: Element, alignTop: CGFloat?) -> (png: Data, inkTop: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: canvas, weight: element.weight)
    guard let symbol = NSImage(systemSymbolName: element.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        FileHandle.standardError.write(Data("找不到符号 \(element.symbol)\n".utf8))
        exit(1)
    }

    let ink = inkBounds(of: symbol)
    let fit = canvas * element.scale / max(ink.width, ink.height)
    let inkWidth = ink.width * fit, inkHeight = ink.height * fit

    // Solve for the symbol image's origin such that its *ink* lands as asked.
    let originX = canvas * (element.x + groupOffsetX) - inkWidth / 2 - ink.minX * fit
    let originY: CGFloat
    switch element.placement {
    case .center(let y):
        originY = canvas * y - inkHeight / 2 - ink.minY * fit
    case .topAlignedWith(let other):
        guard let alignTop else {
            FileHandle.standardError.write(Data("\(element.file) 要对齐的 \(other) 尚未绘制\n".utf8))
            exit(1)
        }
        originY = alignTop - inkHeight - ink.minY * fit
    }

    let (rep, context) = bitmap(Int(canvas), Int(canvas))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // SF Symbols render in the current fill colour only when drawn as a
    // template; compositing white through the glyph's alpha is the reliable
    // way to get a solid white shape.
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
    symbol.draw(at: .zero, from: NSRect(origin: .zero, size: symbol.size),
                operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    tinted.draw(in: CGRect(x: originX, y: originY,
                           width: symbol.size.width * fit,
                           height: symbol.size.height * fit))

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("生成 \(element.file) 失败\n".utf8))
        exit(1)
    }
    return (png, originY + (ink.minY + ink.height) * fit)
}

// MARK: - Manifest

/// Colours are `colorspace:r,g,b,a` with six decimals; actool rejects named
/// colours and anything missing the `:` delimiter.
func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, a)
}

/// Layers list top to bottom. The elements are laid out so they do not overlap,
/// so the order only decides which one wins if a later tweak moves them together.
let layerEntries = elements.map { element in
    """
            {
              "fill" : "automatic",
              "glass" : true,
              "image-name" : "\(element.file)",
              "name" : "\(element.file.replacingOccurrences(of: ".png", with: ""))"
            }
    """
}.joined(separator: ",\n")

/// Only used to bootstrap a missing manifest — see the emit step below. The
/// material settings here mirror what Icon Composer produced when the icon was
/// tuned by hand, so starting from scratch lands in the same place.
let manifest = """
{
  "features" : [
    "refractivity",
    "specular-location"
  ],
  "fill" : {
    "automatic-gradient" : "\(srgb(fill.red, fill.green, fill.blue))"
  },
  "groups" : [
    {
      "blur-material" : null,
      "layers" : [
\(layerEntries)
      ],
      "lighting" : "individual",
      "refractivity" : {
        "depth" : 0,
        "enabled" : true,
        "strength" : 0.4798046875
      },
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "specular" : "inside",
      "translucency" : {
        "enabled" : true,
        "value" : 0.3
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}
"""

// MARK: - Emit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let icon = root.appendingPathComponent("DACBar/Resources/AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")

try fm.createDirectory(at: assets, withIntermediateDirectories: true)

var inkTops: [String: CGFloat] = [:]
for element in elements {
    var alignTop: CGFloat?
    if case .topAlignedWith(let other) = element.placement { alignTop = inkTops[other] }
    let drawn = draw(element, alignTop: alignTop)
    inkTops[element.file] = drawn.inkTop
    try drawn.png.write(to: assets.appendingPathComponent(element.file))
}

// The manifest is only written when there isn't one. Once the icon has been
// opened in Icon Composer it holds hand-tuned material settings — glass,
// refractivity, translucency — that this script has no way to reproduce from
// its inputs, and overwriting it would silently discard that work. Rerunning
// the script therefore refreshes the artwork and leaves the look alone.
//
// Adding or removing an element is the exception: that changes the layer list,
// so the manifest has to be edited to match.
let manifestURL = icon.appendingPathComponent("icon.json")
if fm.fileExists(atPath: manifestURL.path) {
    print("已更新 DACBar/Resources/AppIcon.icon/Assets/（保留现有 icon.json）")
} else {
    try Data(manifest.utf8).write(to: manifestURL)
    print("已生成 DACBar/Resources/AppIcon.icon")
}
