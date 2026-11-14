import CoreGraphics
import CoreML
import Vision

/// Finds tiles, not their values, with the D-FINE detector `Labeler/finder.py` trains, whose `scores` and center
/// `boxes` Vision can't read as objects. Tiles small in a photo are found in its crops.
public struct Finder: @unchecked Sendable {
  let request: VNCoreMLRequest
  /// Tiles under this many px on their short side, in a frame 1920 px long, are out of scope for `score` and `check`:
  /// the far end of a table, which a table panned with ARKit won't need.
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
    for region in [whole] + Self.crops(width: w, height: h) {
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

  /// Squares the short side, three down a 1080p frame, overlapping by about half, spread evenly from edge to edge.
  /// They found 932 of 960 held-out tiles in scope with 14 extras, where squares half that (19 regions) found 937 with
  /// 16.
  static func crops(width: Int, height: Int) -> [CGRect] {
    let s = min(width, height)
    func starts(_ length: Int) -> [Int] {
      let n = Int((Double(length - s) / Double(s / 2)).rounded(.up)) + 1
      return n == 1 ? [0] : (0..<n).map { (length - s) * $0 / (n - 1) }
    }
    return starts(height).flatMap { y in starts(width).map { x in CGRect(x: x, y: y, width: s, height: s) } }
  }

  /// Whether a capture is kept out of training to score on: a fifth of them, by a hash of the name of the recording
  /// it was taken during, else its own, so a recording's frames go together and finishing more captures never moves
  /// one in or out.
  public static func isHeldOut(_ name: String, in captures: URL) -> Bool {
    let notes = (try? Data(contentsOf: captures.appending(path: name + ".json")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let group = notes?["recording"] as? String ?? name
    return group.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } % 5 == 0
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
