import CoreGraphics
import simd

/// Whether a tile stands on a rack or lies on the table, from the shape of its face: cast onto any plane level with the
/// table, a flat tile's top and bottom edges come out the same length, while a standing tile's top edge, higher up,
/// comes out longer. The ratio doesn't depend on how far the plane is, so gravity alone places it.
public enum Standing {
  /// A tile's four corners within its box, top left, top right, bottom right, bottom left: its face is the largest
  /// bright patch, split from what's around it at the brightness that best divides the box (Otsu's).
  public static func corners(in image: CGImage, box: CGRect) -> [CGPoint]? {
    let crop = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1).intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    guard let cropped = image.cropping(to: crop) else { return nil }
    let w = cropped.width, h = cropped.height
    var pixels = [UInt8](repeating: 0, count: w * h)
    guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

    var histogram = [Int](repeating: 0, count: 256)
    for p in pixels { histogram[Int(p)] += 1 }
    let total = Double(w * h), sum = histogram.indices.reduce(0.0) { $0 + Double($1 * histogram[$1]) }
    var below = 0.0, belowSum = 0.0, best = 0.0, threshold = 128
    for t in 0..<256 {
      below += Double(histogram[t])
      belowSum += Double(t * histogram[t])
      guard below > 0, below < total else { continue }
      let a = belowSum / below, b = (sum - belowSum) / (total - below)
      let between = below * (total - below) * (a - b) * (a - b)
      if between > best { (best, threshold) = (between, t) }
    }

    // The bright patches, the largest kept.
    var label = [Int32](repeating: 0, count: w * h)
    var largest = [Int](), next: Int32 = 0
    for start in pixels.indices where pixels[start] > threshold && label[start] == 0 {
      next += 1
      var patch = [start], i = 0
      label[start] = next
      while i < patch.count {
        let p = patch[i]
        i += 1
        let x = p % w, y = p / w
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
          let n = ny * w + nx
          if pixels[n] > threshold && label[n] == 0 {
            label[n] = next
            patch.append(n)
          }
        }
      }
      if patch.count > largest.count { largest = patch }
    }
    guard Double(largest.count) > 0.3 * Double(box.width * box.height) else { return nil }
    let points = largest.map { (x: $0 % w, y: $0 / w) }
    let corners = [
      points.min { $0.x + $0.y < $1.x + $1.y }!, points.max { $0.x - $0.y < $1.x - $1.y }!,
      points.max { $0.x + $0.y < $1.x + $1.y }!, points.min { $0.x - $0.y < $1.x - $1.y }!,
    ]
    return corners.map { CGPoint(x: crop.minX + CGFloat($0.x) + 0.5, y: crop.minY + CGFloat($0.y) + 0.5) }
  }

  /// The top edge's length over the bottom's, cast onto a plane level with the table: about 1 lying on it, more
  /// standing up. `gravity` is the phone's, as CoreMotion gives it; `focal` and `center` in the upright image's pixels.
  public static func taper(_ corners: [CGPoint], gravity: SIMD3<Double>, focal: Double, center: CGPoint) -> Double? {
    let up = -normalize(gravity)
    // The back camera looks along the phone's -z; the upright image's x is its x, y its -y.
    let level = corners.map { p -> SIMD3<Double>? in
      let ray = SIMD3((p.x - center.x) / focal, -(p.y - center.y) / focal, -1)
      let facing = dot(ray, up)
      return facing < 0 ? ray / -facing : nil
    }
    guard let a = level[0], let b = level[1], let c = level[2], let d = level[3] else { return nil }
    return distance(a, b) / distance(d, c)
  }
}
