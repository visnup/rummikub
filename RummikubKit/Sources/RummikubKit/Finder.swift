import CoreGraphics
import CoreML
import Vision

/// Finds tiles, not their values, with a detector trained by `train`. Tiles small in a photo are found in its crops.
public struct Finder: @unchecked Sendable {
  let request: VNCoreMLRequest

  public init(model: MLModel) throws {
    request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
    request.imageCropAndScaleOption = .scaleFill
  }

  /// Boxes in top-left-origin pixels, most confident first. A box cut by a crop's edge is left to the neighboring crop
  /// it's whole in, and one that overlaps a more confident box by over a tenth (IoU) is dropped.
  public func tiles(in image: CGImage) throws -> [CGRect] {
    let (w, h) = (image.width, image.height)
    let whole = CGRect(x: 0, y: 0, width: w, height: h)
    let handler = VNImageRequestHandler(cgImage: image)
    var found = [(box: CGRect, confidence: Float)]()
    for region in [whole] + Self.crops(width: w, height: h, overlap: true) {
      request.regionOfInterest = VNNormalizedRectForImageRect(
        CGRect(x: region.minX, y: Double(h) - region.maxY, width: region.width, height: region.height), w, h)
      try handler.perform([request])
      for o in request.results as? [VNRecognizedObjectObservation] ?? [] where o.confidence > 0.9 {
        let n = VNImageRectForNormalizedRect(o.boundingBox, Int(region.width), Int(region.height))
        let box = CGRect(x: region.minX + n.minX, y: region.maxY - n.maxY, width: n.width, height: n.height)
        let inner = region.insetBy(dx: 2, dy: 2)
        let cut =
          box.minX < inner.minX && region.minX > 0 || box.maxX > inner.maxX && region.maxX < whole.maxX
          || box.minY < inner.minY && region.minY > 0 || box.maxY > inner.maxY && region.maxY < whole.maxY
        if !cut { found.append((box, o.confidence)) }
      }
    }
    var kept = [(box: CGRect, confidence: Float)]()
    for f in found.sorted(by: { $0.confidence > $1.confidence })
    where !kept.contains(where: { Self.overlap($0.box, f.box) > 0.1 }) {
      kept.append(f)
    }
    return kept.map(\.box)
  }

  /// Squares half the short side, side by side or overlapping by half.
  public static func crops(width: Int, height: Int, overlap: Bool) -> [CGRect] {
    let side = min(width, height) / 2
    let step = overlap ? side / 2 : side
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
