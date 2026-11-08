import CoreGraphics
import CoreML
import Vision

/// Finds tiles, not their values, with the D-FINE detector `Labeler/finder.py` trains, whose `scores` and center
/// `boxes` Vision can't read as objects. Tiles small in a photo are found in its crops.
public struct Finder: @unchecked Sendable {
  let request: VNCoreMLRequest

  public init(model: MLModel) throws {
    request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
    request.imageCropAndScaleOption = .scaleFill
    request.onCPUInSimulator()
  }

  /// Boxes in top-left-origin pixels, most confident first. A box cut by a crop's edge is left to the neighboring crop
  /// it's whole in, and one that overlaps a more confident box by over a tenth (IoU) is dropped.
  public func tiles(in image: CGImage) throws -> [CGRect] {
    let (w, h) = (image.width, image.height)
    let whole = CGRect(x: 0, y: 0, width: w, height: h)
    let handler = VNImageRequestHandler(cgImage: image)
    var found = [(box: CGRect, confidence: Float)]()
    for region in [whole] + Self.crops(width: w, height: h) {
      request.regionOfInterest = VNNormalizedRectForImageRect(
        CGRect(x: region.minX, y: Double(h) - region.maxY, width: region.width, height: region.height), w, h)
      try handler.perform([request])
      for (box, confidence) in detections(in: region) where confidence > 0.6 {
        let inner = region.insetBy(dx: 2, dy: 2)
        let cut =
          box.minX < inner.minX && region.minX > 0 || box.maxX > inner.maxX && region.maxX < whole.maxX
          || box.minY < inner.minY && region.minY > 0 || box.maxY > inner.maxY && region.maxY < whole.maxY
        if !cut { found.append((box, confidence)) }
      }
    }
    var kept = [(box: CGRect, confidence: Float)]()
    for f in found.sorted(by: { $0.confidence > $1.confidence })
    where !kept.contains(where: { Self.overlap($0.box, f.box) > 0.1 }) {
      kept.append(f)
    }
    return kept.map(\.box)
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

  /// Squares half the short side, overlapping by half.
  static func crops(width: Int, height: Int) -> [CGRect] {
    let side = min(width, height) / 2
    let step = side / 2
    return stride(from: 0, through: height - side, by: step).flatMap { y in
      stride(from: 0, through: width - side, by: step).map { x in CGRect(x: x, y: y, width: side, height: side) }
    }
  }

  /// Whether a capture is kept out of training to score on: a fifth of them, by a hash of its name, so finishing
  /// more captures never moves one in or out.
  public static func isHeldOut(_ name: String) -> Bool {
    name.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } % 5 == 0
  }

  /// Intersection over union.
  public static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let shared = i.width * i.height
    return shared / (a.width * a.height + b.width * b.height - shared)
  }
}
