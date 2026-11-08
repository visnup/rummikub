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

/// An image classifier: one trained on tile crops reads each of the finder's boxes, its classes tiles (k1…r13, j);
/// one trained on whole frames says whether it's a rack or the table.
public struct Classifier: @unchecked Sendable {
  let request: VNCoreMLRequest

  public init(model: MLModel) throws {
    request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
    request.imageCropAndScaleOption = .scaleFill
    request.onCPUInSimulator()
  }

  /// The most likely class for the whole image, with its probability.
  public func label(of image: CGImage) throws -> (label: String, confidence: Float)? {
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results as? [VNClassificationObservation])?.first.map { ($0.identifier, $0.confidence) }
  }

  /// The most likely tile in each box, where the classifier is at least `least` sure. On the held-out captures .7 read
  /// 435 of 572 right with 79 extras; no cutoff, 470 with 122; .9, 386 with 43.
  public func tiles(in image: CGImage, boxes: [CGRect], least: Float = 0.7) throws -> [Detection] {
    let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // A frame's worth of requests at a time: Vision's buffers otherwise pile up until it fails with "Failed to
    // create CVPixelBufferPool", as it did over thousands of crops.
    return try autoreleasepool { try boxes.compactMap { box in
      guard let crop = image.cropping(to: box.intersection(whole).integral), crop.width >= 8, crop.height >= 8 else {
        return nil
      }
      try VNImageRequestHandler(cgImage: crop).perform([request])
      guard let top = (request.results as? [VNClassificationObservation])?.first, top.confidence >= least,
        let tile = Tile(top.identifier)
      else { return nil }
      return Detection(tile: tile, frame: box)
    } }
  }
}
