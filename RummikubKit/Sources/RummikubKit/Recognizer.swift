import CoreGraphics

public struct Detection: Hashable, Sendable {
  public let tile: Tile
  /// In top-left-origin pixels.
  public let frame: CGRect
}

/// Finds tiles in a photo by their numerals: blobs of ink with tile face all around them, joined into numbers. Each
/// is read by matching its ink against reference glyphs and colored by that ink, and its tile's frame is guessed from
/// its size. Vision's text recognition skips most lone digits, so it's not used.
public enum Recognizer {
  public static func tiles(in image: CGImage) -> [Detection] {
    let pixels = Pixels(image)
    let numerals = pixels.numerals()
    let heights = numerals.map(\.box.height).sorted()
    return numerals.compactMap { numeral in
      let box = numeral.box
      guard let color = pixels.inkColor(in: box), let glyph = pixels.glyph(in: box) else { return nil }
      // A real joker's face is half again as tall as a numeral; a rendered one is the size of one.
      let big = box.height > heights[heights.count / 2] * 1.4 && (0.8...1.25).contains(box.width / box.height)
      let whole = glyphs.min { glyph.distance(to: $0.glyph) < glyph.distance(to: $1.glyph) }!.value
      guard !big, whole != nil else { return Detection(tile: .joker, frame: frame(around: box, height: 0.45)) }
      let read = numeral.digits.map { part in
        let glyph = pixels.glyph(in: part)!
        return digits.min { glyph.distance(to: $0.glyph) < glyph.distance(to: $1.glyph) }!.digit
      }
      let value = Int(read.map(String.init).joined()).flatMap { (1...13).contains($0) ? $0 : nil } ?? whole!
      return Detection(tile: .number(color, value), frame: frame(around: box, height: 0.3))
    }
  }

  /// A tile around a numeral that takes up `height` of it, centered a bit above the middle.
  static func frame(around box: CGRect, height fraction: CGFloat) -> CGRect {
    let height = box.height / fraction
    return CGRect(x: box.midX - height * 0.35, y: box.midY - height * 0.42, width: height * 0.7, height: height)
  }

  /// 1–13, and nil for the joker, cut from tiles rendered in bold fonts close to the real tiles' one, which ships on
  /// no device.
  static let glyphs: [(value: Int?, glyph: Glyph)] = references.flatMap { pixels, numerals in
    zip(referenceTiles, numerals).map { ($0.value, pixels.glyph(in: $1.box)!) }
  }

  /// 0–9 on their own, from the same.
  static let digits: [(digit: Int, glyph: Glyph)] = references.flatMap { pixels, numerals in
    zip(referenceTiles.compactMap(\.value), numerals).flatMap { value, numeral in
      zip(String(value), numeral.digits).map { (Int(String($0))!, pixels.glyph(in: $1)!) }
    }
  }

  static let referenceTiles = (1...13).map { Tile.number(.black, $0) } + [.joker]
  static let references = ["Helvetica-Bold", "Arial-BoldMT", "Futura-Bold", "AvenirNext-Heavy", "Verdana-Bold"].map {
    let pixels = Pixels(Render.table([referenceTiles], height: 300, font: $0).image)
    return (pixels, pixels.numerals().sorted { $0.box.minX < $1.box.minX })
  }

  /// Tiles side by side in the same row, in reading order.
  public static func melds(_ detections: [Detection]) -> [[Detection]] {
    var melds = [[Detection]]()
    for detection in detections.sorted(by: { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }) {
      let frame = detection.frame
      if let i = melds.firstIndex(where: {
        let last = $0.last!.frame
        return abs(last.midY - frame.midY) < frame.height / 3 && abs(frame.minX - last.maxX) < frame.width / 3
      }) {
        melds[i].append(detection)
      } else {
        melds.append([detection])
      }
    }
    return melds.sorted {
      abs($0[0].frame.midY - $1[0].frame.midY) < $0[0].frame.height / 2
        ? $0[0].frame.minX < $1[0].frame.minX : $0[0].frame.midY < $1[0].frame.midY
    }
  }
}

/// How much ink falls in each cell of a small grid.
struct Glyph {
  static let width = 32, height = 24
  /// Scaled to unit length, so how bold a font is matters less than its shape.
  let cells: [Float]

  init(cells: [Float]) {
    let clamped = cells.map { min($0, 1) }
    let length = clamped.reduce(0) { $0 + $1 * $1 }.squareRoot()
    self.cells = clamped.map { $0 / length }
  }

  func distance(to other: Glyph) -> Float {
    1 - zip(cells, other.cells).reduce(0) { $0 + $1.0 * $1.1 }
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
    face = Self.face(rgba)
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
    return abs(s - face.s) < 0.1 && v > face.v - 0.2
  }

  /// The tile face's saturation and value: the most common pair among bright, nearly gray pixels. White balance and
  /// exposure move it around too much between photos for fixed thresholds.
  let face: (s: Double, v: Double)

  static func face(_ rgba: [UInt8]) -> (s: Double, v: Double) {
    var counts = [Int](repeating: 0, count: 20 * 20)
    for i in stride(from: 0, to: rgba.count, by: 4 * 7) {
      let high = Int(max(rgba[i], rgba[i + 1], rgba[i + 2])), low = Int(min(rgba[i], rgba[i + 1], rgba[i + 2]))
      guard high > 127, high > 0 else { continue }
      let s = Double(high - low) / Double(high), v = Double(high) / 255
      guard s < 0.4 else { continue }
      counts[Int(s * 50) * 20 + min(19, Int(v * 20))] += 1
    }
    let peak = counts.indices.max { counts[$0] < counts[$1] }!
    return ((Double(peak / 20) + 0.5) / 50, (Double(peak % 20) + 0.5) / 20)
  }

  let inkValue = 0.35, inkSaturation = 0.5

  /// Dark or strongly colored, unlike the tile face, its embossed logo and its shadowed edges.
  func isInk(_ x: Int, _ y: Int) -> Bool {
    let (_, s, v) = hsv(x, y)
    return v < inkValue || s > inkSaturation
  }

  /// A number's ink blobs: its digits, and the underline of a 6 or 9.
  struct Numeral {
    var parts: [CGRect]
    var box: CGRect { parts.dropFirst().reduce(parts[0]) { $0.union($1) } }
    var digits: [CGRect] { parts.filter { $0.height >= $0.width / 2 }.sorted { $0.minX < $1.minX } }
  }

  /// The numerals on tiles: ink blobs with tile face all around, joined side by side into numbers, with the
  /// underlines of 6 and 9.
  func numerals() -> [Numeral] {
    var ink = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
      for x in 0..<width { ink[y * width + x] = isInk(x, y) }
    }
    var boxes = [CGRect]()
    for start in ink.indices where ink[start] {
      ink[start] = false
      var stack = [start]
      var minX = width, minY = height, maxX = 0, maxY = 0
      while let p = stack.popLast() {
        let x = p % width, y = p / width
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        where nx >= 0 && ny >= 0 && nx < width && ny < height && ink[ny * width + nx] {
          ink[ny * width + nx] = false
          stack.append(ny * width + nx)
        }
      }
      let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      if max(box.width, box.height) >= 4 && onTile(box, share: 0.5) { boxes.append(box) }
    }
    // Drop the features inside a joker's face, but not a numeral inside a stretch of wood grain.
    let containers = boxes.filter { onTile($0, share: 0.75) }
    var numerals = boxes.filter { box in !containers.contains { $0 != box && $0.contains(box) } }.map { Numeral(parts: [$0]) }

    var joined = true
    while joined {
      joined = false
      for i in numerals.indices {
        if let j = numerals.indices.first(where: { $0 != i && belongTogether(numerals[i].box, numerals[$0].box) }) {
          numerals[i].parts += numerals[j].parts
          numerals.remove(at: j)
          joined = true
          break
        }
      }
    }
    // Seams between tiles leave slivers far thinner than a 1.
    return numerals.filter {
      $0.box.height > CGFloat(height) / 60 && $0.box.width > $0.box.height * 0.15 && onTile($0.box, share: 0.75)
    }
  }

  /// Digits of one number, or a 6 or 9 and its underline.
  func belongTogether(_ a: CGRect, _ b: CGRect) -> Bool {
    let tall = max(a.height, b.height)
    let sideBySide =
      min(a.maxY, b.maxY) - max(a.minY, b.minY) > min(a.height, b.height) / 2
      && max(a.minX, b.minX) - min(a.maxX, b.maxX) < tall * 0.7
      && (0.6...1.6).contains(a.height / b.height)
    let (upper, lower) = a.minY < b.minY ? (a, b) : (b, a)
    let underline =
      lower.height < lower.width / 2
      && min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX) > lower.width / 2
      && lower.minY - upper.maxY < upper.height * 0.4
    return sideBySide || underline
  }

  /// Whether at least `share` of the ring around `box`, a fifth of its height out, is tile face.
  func onTile(_ box: CGRect, share: Double) -> Bool {
    let ring = box.insetBy(dx: -box.height / 5, dy: -box.height / 5)
    guard ring.minX >= 0, ring.minY >= 0, ring.maxX < CGFloat(width), ring.maxY < CGFloat(height) else { return false }
    let step = max(1, Int(ring.height) / 12)
    let xs = stride(from: Int(ring.minX), to: Int(ring.maxX), by: step)
    let ys = stride(from: Int(ring.minY), to: Int(ring.maxY), by: step)
    let points =
      xs.flatMap { x in [(x, Int(ring.minY)), (x, Int(ring.maxY) - 1)] }
      + ys.flatMap { y in [(Int(ring.minX), y), (Int(ring.maxX) - 1, y)] }
    return Double(points.count { isTileFace($0.0, $0.1) }) >= Double(points.count) * share
  }

  /// The ink inside `box`, scaled to `Glyph.height` and centered, or nil when there's too little.
  func glyph(in box: CGRect) -> Glyph? {
    var ink = [(x: Int, y: Int)]()
    for y in Int(box.minY)..<Int(box.maxY) {
      for x in Int(box.minX)..<Int(box.maxX) where isInk(x, y) { ink.append((x, y)) }
    }
    guard ink.count > 10 else { return nil }
    let scale = Double(Glyph.height) / box.height
    let offset = (Double(Glyph.width) - box.width * scale) / 2
    var cells = [Float](repeating: 0, count: Glyph.width * Glyph.height)
    for (x, y) in ink {
      let column = Int((Double(x) - box.minX) * scale + offset), row = Int((Double(y) - box.minY) * scale)
      guard (0..<Glyph.width).contains(column), row < Glyph.height else { continue }
      cells[row * Glyph.width + column] += Float(scale * scale)
    }
    return Glyph(cells: cells)
  }

  /// The color of the saturated or dark pixels inside `box`.
  func inkColor(in box: CGRect) -> TileColor? {
    var hues = [Double]()
    var dark = 0
    for y in Int(box.minY)..<Int(box.maxY) {
      for x in Int(box.minX)..<Int(box.maxX) {
        let (h, s, v) = hsv(x, y)
        // Black ink under a color cast is saturated too, but darker than any colored ink.
        if s > inkSaturation && v > 0.3 { hues.append(h) } else if v < inkValue { dark += 1 }
      }
    }
    guard hues.count + dark > 10 else { return nil }
    if dark > hues.count { return .black }
    let reds = hues.count { $0 < 15 || $0 > 330 }
    let oranges = hues.count { (15..<60).contains($0) }
    let blues = hues.count { (150..<270).contains($0) }
    return [(TileColor.red, reds), (.orange, oranges), (.blue, blues)].max { $0.1 < $1.1 }!.0
  }
}
