import CoreGraphics
import CoreText
import Foundation

/// Draws tiles flat on a table, for testing recognition without a camera.
public enum Render {
  public static let tileSize = CGSize(width: 60, height: 84)

  /// Table melds in rows from `top` down, then the rack `bottom` up from the bottom edge. Returns the image and each
  /// tile's frame in top-left-origin pixels, table tiles first in reading order, then the rack.
  public static func table(
    _ melds: [[Tile]], rack: [Tile] = [], width: Int = 1200, height: Int = 900, top: CGFloat = 30,
    bottom: CGFloat = 50, font: String = "Helvetica-Bold"
  )
    -> (image: CGImage, frames: [CGRect])
  {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(srgbRed: 0.13, green: 0.35, blue: 0.22, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    var frames = [CGRect]()
    var origin = CGPoint(x: 30, y: top)
    let gap: CGFloat = 40
    for meld in melds {
      let meldWidth = CGFloat(meld.count) * (tileSize.width + 2)
      if origin.x + meldWidth > CGFloat(width) - 30 {
        origin = CGPoint(x: 30, y: origin.y + tileSize.height + 30)
      }
      for (i, tile) in meld.enumerated() {
        let frame = CGRect(origin: CGPoint(x: origin.x + CGFloat(i) * (tileSize.width + 2), y: origin.y), size: tileSize)
        draw(tile, in: frame, context: context, font: font)
        frames.append(frame)
      }
      origin.x += meldWidth + gap
    }
    context.setFillColor(CGColor(srgbRed: 0.35, green: 0.22, blue: 0.12, alpha: 1))
    let rackY = CGFloat(height) - tileSize.height - bottom
    context.fill(CGRect(x: 0, y: rackY - 10, width: CGFloat(width), height: CGFloat(height) - rackY + 10))
    for (i, tile) in rack.enumerated() {
      let frame = CGRect(origin: CGPoint(x: 30 + CGFloat(i) * (tileSize.width + 4), y: rackY), size: tileSize)
      draw(tile, in: frame, context: context, font: font)
      frames.append(frame)
    }
    return (context.makeImage()!, frames)
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
      case .label(let rect, let tile):
        context.setStrokeColor(highlight)
        context.setLineWidth(3)
        context.stroke(rect)
        text(line(tile.description, size: rect.height / 4, color: highlight), at: CGPoint(x: rect.minX, y: rect.maxY + rect.height / 4))
        context.setLineWidth(5)
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

  static func draw(_ tile: Tile, in frame: CGRect, context: CGContext, font: String = "Helvetica-Bold") {
    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.93, blue: 0.85, alpha: 1))
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
    context.fillPath()
    let text: String
    let color: CGColor
    switch tile {
    case .number(let tileColor, let value):
      text = "\(value)"
      color = ink[tileColor]!
    case .joker:
      text = "☺"
      color = ink[.red]!
    }
    let font = CTFontCreateWithName(font as CFString, 36, nil)
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if tile.value == 6 || tile.value == 9 {
      attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.thick.rawValue
    }
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
