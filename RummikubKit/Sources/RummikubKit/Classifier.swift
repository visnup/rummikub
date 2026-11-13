import CoreGraphics
import CoreML
import Vision

extension VNRequest {
  /// Every stage on the CPU in the Simulator, the feature extraction Vision runs before the model included, which
  /// the model's own `computeUnits` doesn't reach: elsewhere it fails with "Could not create inference context".
  func onCPUInSimulator() {
    #if targetEnvironment(simulator)
      for (stage, devices) in (try? supportedComputeStageDevices) ?? [:] {
        if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) { setComputeDevice(cpu, for: stage) }
      }
    #endif
  }
}

/// Values, an image classifier that reads each of the finder's boxes, its classes tiles at an orientation, maybe on a
/// rack ("k6@2@rack").
public struct Classifier: @unchecked Sendable {
  let model: VNCoreMLModel

  public init(model: MLModel) throws {
    self.model = try VNCoreMLModel(for: model)
  }

  /// The most likely tile in each box, where the image classifier is at least `least` sure, with its odds at each
  /// orientation for `Recognizer.turned`.
  public func tiles(in image: CGImage, boxes: [CGRect], least: Float = 0.5) throws -> [Detection] {
    let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let kept = boxes.filter { let r = $0.intersection(whole).integral; return r.width >= 8 && r.height >= 8 }
    // A frame's worth of requests at a time: Vision's buffers otherwise pile up until it fails with "Failed to
    // create CVPixelBufferPool", as it did over thousands of crops.
    let read: [[String: Float]] = try autoreleasepool {
      // One handler for the frame, a request per box, so the frame is prepared once.
      let requests = kept.map { box in
        let r = box.intersection(whole).integral
        let each = VNCoreMLRequest(model: model)
        each.imageCropAndScaleOption = .scaleFill
        each.regionOfInterest = VNNormalizedRectForImageRect(
          CGRect(x: r.minX, y: whole.height - r.maxY, width: r.width, height: r.height), image.width, image.height)
        each.onCPUInSimulator()
        return each
      }
      try VNImageRequestHandler(cgImage: image).perform(requests)
      return requests.map { r in
        Dictionary(((r.results as? [VNClassificationObservation]) ?? []).map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
      }
    }
    return zip(kept, read).compactMap { box, probabilities in
      // Classes are tiles, or tiles at a turn ("k6@2"), summed over turns, and maybe on a rack ("k6@2@rack").
      var turned = [Tile: [Float]](), rack: Float?
      for (label, p) in probabilities {
        let parts = label.split(separator: "@")
        guard let tile = Tile(parts[0]) else { continue }
        turned[tile, default: [0, 0, 0, 0]][parts.count > 1 ? Int(parts[1])! : 0] += p
        if parts.count > 2 { rack = (rack ?? 0) + p }
      }
      let odds = turned.mapValues { $0.reduce(0, +) }.filter { $0.value >= 0.001 }
      guard let (tile, confidence) = odds.max(by: { $0.value < $1.value }), confidence >= least else { return nil }
      return Detection(tile: tile, frame: box, odds: odds, turned: turned, rack: rack)
    }
  }
}
