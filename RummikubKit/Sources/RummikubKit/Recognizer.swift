import CoreGraphics

public struct Detection: Hashable, Sendable {
  public let tile: Tile
  /// In top-left-origin pixels.
  public let frame: CGRect
}

/// Finds tiles in a photo: cream-colored blobs split into tile-shaped pieces, each read by matching its ink against
/// reference glyphs and colored by that ink. Vision's text recognition skips most lone digits, so it's not used.
public enum Recognizer {
  public static func tiles(in image: CGImage) -> [Detection] {
    let pixels = Pixels(image)
    return pixels.tileFrames().compactMap { frame in
      guard let color = pixels.inkColor(in: frame), let glyph = pixels.glyph(in: frame) else { return nil }
      let value = glyphs.min { glyph.distance(to: $0.glyph) < glyph.distance(to: $1.glyph) }!.value
      return Detection(tile: value.map { .number(color, $0) } ?? .joker, frame: frame)
    }
  }

  /// 1–13, and nil for the joker, cut from rendered tiles.
  static let glyphs: [(value: Int?, glyph: Glyph)] = {
    let tiles = (1...13).map { Tile.number(.black, $0) } + [.joker]
    let (image, frames) = Render.table([tiles], height: 300)
    let pixels = Pixels(image)
    return zip(tiles, frames).map { ($0.value, pixels.glyph(in: $1)!) }
  }()

  /// Tiles side by side in the same row, in reading order.
  public static func melds(_ detections: [Detection]) -> [[Detection]] {
    var melds = [[Detection]]()
    for detection in detections.sorted(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
      let frame = detection.frame
      if let i = melds.firstIndex(where: {
        let last = $0.last!.frame
        return abs(last.midY - frame.midY) < frame.height / 2 && abs(frame.minX - last.maxX) < frame.width / 3
      }) {
        melds[i].append(detection)
      } else {
        melds.append([detection])
      }
    }
    return melds.sorted { ($0[0].frame.minY, $0[0].frame.minX) < ($1[0].frame.minY, $1[0].frame.minX) }
  }
}

/// How much ink falls in each cell of a small grid.
struct Glyph {
  static let width = 32, height = 24
  let cells: [Float]

  func distance(to other: Glyph) -> Float {
    zip(cells, other.cells).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
  }
}

struct Pixels {
  let width: Int
  let height: Int
  let rgba: [UInt8]

  init(_ image: CGImage) {
    let width = image.width, height = image.height
    self.width = width
    self.height = height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes {
      let context = CGContext(
        data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    self.rgba = rgba
  }

  /// Hue in degrees, saturation and value, all from the pixel at top-left-origin `x`, `y`.
  func hsv(_ x: Int, _ y: Int) -> (h: Double, s: Double, v: Double) {
    let i = (y * width + x) * 4
    let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
    let v = max(r, g, b), delta = v - min(r, g, b)
    guard delta > 0 else { return (0, 0, v) }
    let h: Double =
      v == r ? (g - b) / delta : v == g ? (b - r) / delta + 2 : (r - g) / delta + 4
    return ((h * 60 + 360).truncatingRemainder(dividingBy: 360), delta / v, v)
  }

  func isTileFace(_ x: Int, _ y: Int) -> Bool {
    let (_, s, v) = hsv(x, y)
    return v > 0.7 && s < 0.3
  }

  /// Bounding boxes of tile-colored regions, each split into as many tiles as its shape fits.
  func tileFrames() -> [CGRect] {
    var seen = [Bool](repeating: false, count: width * height)
    var frames = [CGRect]()
    for start in 0..<(width * height) where !seen[start] && isTileFace(start % width, start / width) {
      var stack = [start]
      seen[start] = true
      var minX = width, minY = height, maxX = 0, maxY = 0, count = 0
      while let p = stack.popLast() {
        let x = p % width, y = p / width
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        count += 1
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        where nx >= 0 && ny >= 0 && nx < width && ny < height && !seen[ny * width + nx] && isTileFace(nx, ny) {
          seen[ny * width + nx] = true
          stack.append(ny * width + nx)
        }
      }
      let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      guard box.height > 20, count > 200 else { continue }
      let n = max(1, Int((box.width / (box.height * 0.72)).rounded()))
      let tileWidth = box.width / CGFloat(n)
      frames += (0..<n).map { CGRect(x: box.minX + CGFloat($0) * tileWidth, y: box.minY, width: tileWidth, height: box.height) }
    }
    return frames
  }

  /// The ink inside `frame`, scaled to `Glyph.height` and centered, or nil when there's too little.
  func glyph(in frame: CGRect) -> Glyph? {
    let inner = frame.insetBy(dx: 4, dy: 4)
    var ink = [(x: Int, y: Int)]()
    for y in Int(inner.minY)..<Int(inner.maxY) {
      for x in Int(inner.minX)..<Int(inner.maxX) where !isTileFace(x, y) { ink.append((x, y)) }
    }
    guard ink.count > 30 else { return nil }
    let minX = ink.map(\.x).min()!, maxX = ink.map(\.x).max()!
    let minY = ink.map(\.y).min()!, maxY = ink.map(\.y).max()!
    let scale = Double(Glyph.height) / Double(maxY - minY + 1)
    let offset = (Double(Glyph.width) - Double(maxX - minX + 1) * scale) / 2
    var cells = [Float](repeating: 0, count: Glyph.width * Glyph.height)
    for (x, y) in ink {
      let column = Int(Double(x - minX) * scale + offset), row = Int(Double(y - minY) * scale)
      guard (0..<Glyph.width).contains(column), row < Glyph.height else { continue }
      cells[row * Glyph.width + column] += Float(scale * scale)
    }
    return Glyph(cells: cells)
  }

  /// The color of the saturated or dark pixels inside `frame`, or nil when there are too few to be a numeral.
  func inkColor(in frame: CGRect) -> TileColor? {
    var hues = [Double]()
    var dark = 0
    for y in Int(frame.minY)..<Int(frame.maxY) {
      for x in Int(frame.minX)..<Int(frame.maxX) {
        let (h, s, v) = hsv(x, y)
        if v < 0.35 { dark += 1 } else if s > 0.5 { hues.append(h) }
      }
    }
    guard hues.count + dark > 30 else { return nil }
    if dark > hues.count { return .black }
    let reds = hues.count { $0 < 15 || $0 > 330 }
    let oranges = hues.count { (15..<60).contains($0) }
    let blues = hues.count { (180..<270).contains($0) }
    return [(TileColor.red, reds), (.orange, oranges), (.blue, blues)].max { $0.1 < $1.1 }!.0
  }
}
