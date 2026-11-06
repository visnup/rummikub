import CoreGraphics
import CoreText
import Foundation

/// Draws tiles flat on a table, for testing recognition without a camera.
public enum Render {
  public static let tileSize = CGSize(width: 60, height: 84)

  /// Table melds in rows from the top, then the rack along the bottom. Returns the image and each tile's frame in
  /// top-left-origin pixels, table tiles first in reading order, then the rack.
  public static func table(_ melds: [[Tile]], rack: [Tile] = [], width: Int = 1200, height: Int = 900)
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
    var origin = CGPoint(x: 30, y: 30)
    let gap: CGFloat = 40
    for meld in melds {
      let meldWidth = CGFloat(meld.count) * (tileSize.width + 2)
      if origin.x + meldWidth > CGFloat(width) - 30 {
        origin = CGPoint(x: 30, y: origin.y + tileSize.height + 30)
      }
      for (i, tile) in meld.enumerated() {
        let frame = CGRect(origin: CGPoint(x: origin.x + CGFloat(i) * (tileSize.width + 2), y: origin.y), size: tileSize)
        draw(tile, in: frame, context: context)
        frames.append(frame)
      }
      origin.x += meldWidth + gap
    }
    context.setFillColor(CGColor(srgbRed: 0.35, green: 0.22, blue: 0.12, alpha: 1))
    let rackY = CGFloat(height) - tileSize.height - 50
    context.fill(CGRect(x: 0, y: rackY - 10, width: CGFloat(width), height: tileSize.height + 60))
    for (i, tile) in rack.enumerated() {
      let frame = CGRect(origin: CGPoint(x: 30 + CGFloat(i) * (tileSize.width + 4), y: rackY), size: tileSize)
      draw(tile, in: frame, context: context)
      frames.append(frame)
    }
    return (context.makeImage()!, frames)
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
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if tile.value == 6 || tile.value == 9 {
      attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.thick.rawValue
    }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetImageBounds(line, context)
    context.saveGState()
    context.translateBy(x: frame.midX - bounds.midX, y: frame.minY + 50)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
