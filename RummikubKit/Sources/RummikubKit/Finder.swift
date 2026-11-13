import CoreGraphics
import CoreML
import Vision

/// Finds tiles, not their values, with the D-FINE detector `Labeler/finder.py` trains, whose `scores` and center
/// `boxes` Vision can't read as objects. Tiles small in a photo are found in its crops.
public struct Finder: @unchecked Sendable {
  let request: VNCoreMLRequest
  /// Whether to look in crops too, for tiles too small to find in the whole image.
  public var cropped = true
  /// The crops' side, as a share of the image's short side. Squares the whole short side, three down a 1080p frame,
  /// found 932 of 960 held-out tiles in scope with 14 extras, where half of it (19 regions) found 937 with 16.
  public var side = 1.0
  /// Tiles under this many px on their short side, in a frame 1920 px long, are out of scope for `score` and `check`:
  /// the far end of a table, which a table panned with ARKit won't need. The table behind a rack is nearer, and
  /// `nearest` leaves it out.
  public static let smallest = 30.0
  /// Skips the crops when every box the whole image finds is at least this many px on its short side, in a frame
  /// 1920 px long, since then there are no small tiles to look closer for.
  public var enough: Double?
  /// Boxes less confident than this are dropped.
  public var confidence: Float = 0.6

  public init(model: MLModel) throws {
    request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
    request.imageCropAndScaleOption = .scaleFill
    request.onCPUInSimulator()
  }

  /// Boxes in top-left-origin pixels, most confident first. A box cut by a crop's edge is left to the neighboring crop
  /// it's whole in, and one that overlaps a more confident box by over .3 (IoU) is dropped. Angled tiles' neighbors
  /// overlap by up to .25; .1 dropped them, and .4 up let more duplicates through.
  public func tiles(in image: CGImage) throws -> [CGRect] { try find(in: image).boxes }

  /// The boxes, and how many regions it took to find them.
  public func find(in image: CGImage) throws -> (boxes: [CGRect], regions: Int) {
    let (found, regions) = try scored(in: image)
    return (found.map(\.box), regions)
  }

  /// The boxes with their confidences, and how many regions it took to find them.
  public func scored(in image: CGImage) throws -> (found: [(box: CGRect, confidence: Float)], regions: Int) {
    let (w, h) = (image.width, image.height)
    let whole = CGRect(x: 0, y: 0, width: w, height: h)
    let handler = VNImageRequestHandler(cgImage: image)
    var found = [(box: CGRect, confidence: Float)]()
    var regions = 0
    for region in [whole] + (cropped ? Self.crops(width: w, height: h, side: side) : []) {
      // Decided once, after the whole image.
      if regions == 1, let enough, !found.isEmpty,
        found.allSatisfy({ min($0.box.width, $0.box.height) * 1920 / Double(max(w, h)) >= enough })
      {
        break
      }
      regions += 1
      request.regionOfInterest = VNNormalizedRectForImageRect(
        CGRect(x: region.minX, y: Double(h) - region.maxY, width: region.width, height: region.height), w, h)
      try handler.perform([request])
      for (box, confidence) in detections(in: region) where confidence > self.confidence {
        let inner = region.insetBy(dx: 2, dy: 2)
        let cut =
          box.minX < inner.minX && region.minX > 0 || box.maxX > inner.maxX && region.maxX < whole.maxX
          || box.minY < inner.minY && region.minY > 0 || box.maxY > inner.maxY && region.maxY < whole.maxY
        if !cut { found.append((box, confidence)) }
      }
    }
    var kept = [(box: CGRect, confidence: Float)]()
    for f in found.sorted(by: { $0.confidence > $1.confidence })
    where !kept.contains(where: { Self.overlap($0.box, f.box) > 0.3 }) {
      kept.append(f)
    }
    return (kept, regions)
  }

  /// The last request's boxes in the image's top-left-origin pixels.
  func detections(in region: CGRect) -> [(box: CGRect, confidence: Float)] {
    var features = [String: [Float]]()
    for case let o as VNCoreMLFeatureValueObservation in request.results ?? [] {
      if let array = o.featureValue.multiArrayValue { features[o.featureName] = MLShapedArray<Float>(converting: array).scalars }
    }
    guard let scores = features["scores"], let boxes = features["boxes"] else { return [] }
    return scores.indices.map { i in
      let cx = Double(boxes[4 * i]), cy = Double(boxes[4 * i + 1])
      let w = Double(boxes[4 * i + 2]), h = Double(boxes[4 * i + 3])
      let box = CGRect(
        x: region.minX + (cx - w / 2) * region.width, y: region.minY + (cy - h / 2) * region.height,
        width: w * region.width, height: h * region.height)
      return (box, scores[i])
    }
  }

  /// Squares `side` of the short side, overlapping by about half, spread evenly from edge to edge.
  static func crops(width: Int, height: Int, side: Double) -> [CGRect] {
    let s = Int(Double(min(width, height)) * side)
    func starts(_ length: Int) -> [Int] {
      let n = Int((Double(length - s) / Double(s / 2)).rounded(.up)) + 1
      return n == 1 ? [0] : (0..<n).map { (length - s) * $0 / (n - 1) }
    }
    return starts(height).flatMap { y in starts(width).map { x in CGRect(x: x, y: y, width: s, height: s) } }
  }

  /// Whether a capture is kept out of training to score on: a fifth of them, by a hash of its name, so finishing
  /// more captures never moves one in or out.
  public static func isHeldOut(_ name: String) -> Bool {
    name.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } % 5 == 0
  }

  /// The boxes at least .4 as tall as the tallest. A rack's tiles stand nearest, so this drops the table's behind it,
  /// which lie flat. On the 15 rack captures with the table marked background (2026-11-10), .4 dropped 5 of 300 rack
  /// tiles and kept 49 of 307 table ones; .5 dropped 34 and kept 32. No cutoff on height, width, area or either side
  /// did better: in #284 and #285 the table's tiles are as big as the rack's, and a back-row tile hidden by the one in
  /// front loses height.
  public static func nearest(_ boxes: [CGRect]) -> [CGRect] {
    let tallest = boxes.map(\.height).max() ?? 0
    return boxes.filter { $0.height >= tallest * 0.4 }
  }

  /// Whether a tile's box is big enough to be in scope, in an image this size.
  public static func inScope(_ box: CGRect, width: Int, height: Int, smallest: Double = smallest) -> Bool {
    min(box.width, box.height) * 1920 / Double(max(width, height)) >= smallest
  }

  /// Intersection over union.
  public static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let shared = i.width * i.height
    return shared / (a.width * a.height + b.width * b.height - shared)
  }
}
