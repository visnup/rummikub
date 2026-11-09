#if os(macOS)
  import CoreML
  import CreateML
  import CryptoKit
  import Foundation
  import TabularData
  import Vision

  // Trains a classifier on folders of crops named by their class, as `Labeler/crops.py` writes them: Vision's feature
  // print of each crop, then logistic regression on those. Feature prints are kept by crop content in `<crops>.features`,
  // so a rerun only reads new crops: Create ML's own image classifier redid all 13,000 every time (about 8 minutes).
  //   looking <crops> <model>
  setvbuf(stdout, nil, _IOLBF, 0)
  let crops = URL(filePath: CommandLine.arguments[1]), model = URL(filePath: CommandLine.arguments[2])
  let cacheURL = crops.appendingPathExtension("features")

  /// Hash → feature print, read from and written back to a flat file: 32 bytes of hash, then the floats.
  var cache = [Data: [Float]]()
  if let data = try? Data(contentsOf: cacheURL), data.count >= 4 {
    let count = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) }), record = 32 + count * 4
    var offset = 4
    while offset + record <= data.count {
      let key = data.subdata(in: offset..<offset + 32)
      cache[key] = data.subdata(in: offset + 32..<offset + record).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      offset += record
    }
  }

  var labels = [String](), features = [[Float]]()
  var read = 0
  for label in try FileManager.default.contentsOfDirectory(atPath: crops.path).sorted() where !label.hasPrefix(".") {
    for file in try FileManager.default.contentsOfDirectory(atPath: crops.appending(path: label).path) where file.hasSuffix(".jpg") {
      let data = try Data(contentsOf: crops.appending(path: label).appending(path: file))
      let key = Data(SHA256.hash(data: data))
      if cache[key] == nil {
        try autoreleasepool {
          let request = VNGenerateImageFeaturePrintRequest()
          request.imageCropAndScaleOption = .scaleFill
          try VNImageRequestHandler(data: data).perform([request])
          cache[key] = request.results?.first?.floats
        }
        read += 1
        if read % 1000 == 0 { print("read", read, "new crops") }
      }
      if let print = cache[key] {
        labels.append(label)
        features.append(print)
      }
    }
  }
  print("read", read, "new crops of", features.count)
  if let count = cache.values.first?.count {
    var out = Data()
    withUnsafeBytes(of: UInt32(count)) { out.append(contentsOf: $0) }
    for (key, print) in cache where print.count == count {
      out.append(key)
      print.withUnsafeBytes { out.append(contentsOf: $0) }
    }
    try out.write(to: cacheURL)
  }

  var frame = DataFrame()
  frame.append(column: Column(name: "label", contents: labels))
  frame.append(column: Column(name: "features", contents: features.map { MLShapedArray<Float>(scalars: $0, shape: [$0.count]) }))
  let (training, validation) = frame.randomSplit(by: 0.9, seed: 0)
  let classifier = try MLLogisticRegressionClassifier(
    trainingData: DataFrame(training), targetColumn: "label", featureColumns: ["features"],
    parameters: .init(validation: .dataFrame(DataFrame(validation)), maxIterations: 100))
  print("validation accuracy", 1 - classifier.validationMetrics.classificationError)
  try classifier.write(to: model)

  extension VNFeaturePrintObservation {
    var floats: [Float] { data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
  }
#endif
