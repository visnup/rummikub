import CoreGraphics
import CoreText
import Foundation

/// Draws tiles flat on a table, for testing plays and their overlays without a camera.
public enum Render {
  static let tileSize = CGSize(width: 60, height: 84)

  /// Where `table` draws each tile: melds in rows from `top` down, then the rack `bottom` up from the bottom edge.
  public static func scene(
    _ melds: [[Tile]], rack: [Tile] = [], width: Int = 1200, height: Int = 900, top: CGFloat = 30, bottom: CGFloat = 50
  ) -> Scene {
    var origin = CGPoint(x: 30, y: top)
    let table = melds.map { meld in
      let meldWidth = CGFloat(meld.count) * (tileSize.width + 2)
      if origin.x + meldWidth > CGFloat(width) - 30 {
        origin = CGPoint(x: 30, y: origin.y + tileSize.height + 30)
      }
      defer { origin.x += meldWidth + 40 }
      return meld.enumerated().map { i, tile in
        Detection(tile: tile, frame: CGRect(origin: CGPoint(x: origin.x + CGFloat(i) * (tileSize.width + 2), y: origin.y), size: tileSize))
      }
    }
    let rackY = CGFloat(height) - tileSize.height - bottom
    return Scene(table: table, rack: rack.enumerated().map { i, tile in
      Detection(tile: tile, frame: CGRect(origin: CGPoint(x: 30 + CGFloat(i) * (tileSize.width + 4), y: rackY), size: tileSize))
    })
  }

  /// The table and rack `scene` lays out, drawn.
  public static func table(
    _ melds: [[Tile]], rack: [Tile] = [], width: Int = 1200, height: Int = 900, top: CGFloat = 30, bottom: CGFloat = 50
  ) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(srgbRed: 0.13, green: 0.35, blue: 0.22, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scene = scene(melds, rack: rack, width: width, height: height, top: top, bottom: bottom)
    for detection in scene.table.joined() { draw(detection.tile, in: detection.frame, context: context) }
    context.setFillColor(CGColor(srgbRed: 0.35, green: 0.22, blue: 0.12, alpha: 1))
    let rackY = CGFloat(height) - tileSize.height - bottom
    context.fill(CGRect(x: 0, y: rackY - 10, width: CGFloat(width), height: CGFloat(height) - rackY + 10))
    for detection in scene.rack { draw(detection.tile, in: detection.frame, context: context) }
    return context.makeImage()!
  }

  /// `image` with `marks` drawn over it.
  public static func overlay(_ image: CGImage, _ marks: [Mark]) -> CGImage {
    let width = image.width, height = image.height
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let highlight = CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
    context.setLineWidth(5)
    for mark in marks {
      switch mark {
      case .source(let rect):
        context.setStrokeColor(highlight)
        context.stroke(rect.insetBy(dx: -4, dy: -4))
      case .target(let rect, let tile):
        context.setAlpha(0.6)
        draw(tile, in: rect, context: context)
        context.setAlpha(1)
        context.setStrokeColor(highlight)
        context.setLineDash(phase: 0, lengths: [10, 6])
        context.stroke(rect.insetBy(dx: -4, dy: -4))
        context.setLineDash(phase: 0, lengths: [])
      case .arrow(let from, let to):
        let angle = atan2(to.y - from.y, to.x - from.x)
        context.setStrokeColor(highlight)
        context.move(to: from)
        context.addLine(to: to)
        for side in [-1.0, 1.0] {
          context.move(to: to)
          context.addLine(to: CGPoint(x: to.x - 24 * cos(angle + side * 0.5), y: to.y - 24 * sin(angle + side * 0.5)))
        }
        context.strokePath()
      case .caption(let caption):
        let line = line(caption, size: 40, color: highlight)
        text(line, at: CGPoint(x: CGFloat(width) - CTLineGetTypographicBounds(line, nil, nil, nil) - 30, y: 60))
      }
    }
    func line(_ string: String, size: CGFloat, color: CGColor) -> CTLine {
      let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
      return CTLineCreateWithAttributedString(
        NSAttributedString(
          string: string,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
          ]))
    }
    func text(_ line: CTLine, at point: CGPoint) {
      context.saveGState()
      context.translateBy(x: point.x, y: point.y)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = .zero
      CTLineDraw(line, context)
      context.restoreGState()
    }
    return context.makeImage()!
  }

  static let ink: [TileColor: CGColor] = [
    .black: CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1),
    .blue: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.75, alpha: 1),
    .orange: CGColor(srgbRed: 0.95, green: 0.55, blue: 0.08, alpha: 1),
    .red: CGColor(srgbRed: 0.82, green: 0.1, blue: 0.12, alpha: 1),
  ]

  static func draw(_ tile: Tile, in frame: CGRect, context: CGContext) {
    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.93, blue: 0.85, alpha: 1))
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
    context.fillPath()
    var name = "Helvetica-Bold"
    let text: String
    let color: CGColor
    switch tile {
    case .number(let tileColor, let value):
      text = "\(value)"
      color = ink[tileColor]!
    case .joker:
      text = "☺"
      color = ink[.red]!
      // Fonts without ☺ fall back to Apple Color Emoji on iOS, a filled disc.
      name = "Arial-BoldMT"
    }
    let font = CTFontCreateWithName(name as CFString, 36, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.saveGState()
    context.translateBy(x: frame.midX - width / 2, y: frame.minY + 50)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
