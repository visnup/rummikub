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
  /// An image classifier, run through Vision.
  let request: VNCoreMLRequest?
  /// Or one over Vision's feature print, as the `values` tool trains them, with the print as its "features" input.
  let model: MLModel?

  public init(model: MLModel) throws {
    if model.modelDescription.inputDescriptionsByName["features"] != nil {
      self.model = model
      request = nil
    } else {
      request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
      request!.imageCropAndScaleOption = .scaleFill
      request!.onCPUInSimulator()
      self.model = nil
    }
  }

  /// The most likely class for the whole image, with its probability.
  public func label(of image: CGImage) throws -> (label: String, confidence: Float)? {
    try probabilities(of: image).max { $0.value < $1.value }.map { ($0.key, $0.value) }
  }

  /// Every class's probability for the whole image.
  public func probabilities(of image: CGImage) throws -> [String: Float] {
    if let model {
      let print = VNGenerateImageFeaturePrintRequest()
      // Stretched square, as the crops it was trained on were.
      print.imageCropAndScaleOption = .scaleFill
      print.onCPUInSimulator()
      try VNImageRequestHandler(cgImage: image).perform([print])
      guard let observation = print.results?.first else { return [:] }
      let features = observation.data.withUnsafeBytes { MLShapedArray<Float>(scalars: $0.bindMemory(to: Float.self), shape: [observation.elementCount]) }
      let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": MLMultiArray(features)]))
      let probabilities = output.featureValue(for: "labelProbability")?.dictionaryValue as? [String: Double] ?? [:]
      return probabilities.mapValues(Float.init)
    }
    try VNImageRequestHandler(cgImage: image).perform([request!])
    return Dictionary(
      ((request!.results as? [VNClassificationObservation]) ?? []).map { ($0.identifier, $0.confidence) },
      uniquingKeysWith: max)
  }

  /// The most likely tile in each box, where the classifier is at least `least` sure. On the held-out captures .7 read
  /// 435 of 572 right with 79 extras; no cutoff, 470 with 122; .9, 386 with 43.
  public func tiles(in image: CGImage, boxes: [CGRect], least: Float = 0.7) throws -> [Detection] {
    let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // A frame's worth of requests at a time: Vision's buffers otherwise pile up until it fails with "Failed to
    // create CVPixelBufferPool", as it did over thousands of crops.
    return try autoreleasepool { try boxes.compactMap { box in
      guard let crop = image.cropping(to: box.intersection(whole).integral), crop.width >= 8, crop.height >= 8
      else { return nil }
      let odds = try probabilities(of: crop).reduce(into: [Tile: Float]()) { odds, class_ in
        if let tile = Tile(class_.key), class_.value >= 0.001 { odds[tile] = class_.value }
      }
      guard let (tile, confidence) = odds.max(by: { $0.value < $1.value }), confidence >= least else { return nil }
      return Detection(tile: tile, frame: box, odds: odds)
    } }
  }
}
