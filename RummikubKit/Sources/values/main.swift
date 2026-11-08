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
  //   values <crops> <model>
  //   values --turns <model> <crops>
  // instead prints how far each crop is turned, "<tile>/<file>\t<turns>\t<share>", by a model whose classes are tiles
  // at a turn ("k6@2"), as the share of its own tile's odds at that turn.
  setvbuf(stdout, nil, _IOLBF, 0)
  let turns = CommandLine.arguments[1] == "--turns"
  let arguments = Array(CommandLine.arguments.dropFirst(turns ? 2 : 1))
  let crops = URL(filePath: arguments[turns ? 1 : 0]), model = URL(filePath: arguments[turns ? 0 : 1])
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

  var labels = [String](), features = [[Float]](), files = [String]()
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
        if read % 1000 == 0 && !turns { print("read", read, "new crops") }
      }
      if let print = cache[key] {
        labels.append(label)
        features.append(print)
        files.append("\(label)/\(file)")
      }
    }
  }
  if !turns { print("read", read, "new crops of", features.count) }
  if let count = cache.values.first?.count {
    var out = Data()
    withUnsafeBytes(of: UInt32(count)) { out.append(contentsOf: $0) }
    for (key, print) in cache where print.count == count {
      out.append(key)
      print.withUnsafeBytes { out.append(contentsOf: $0) }
    }
    try out.write(to: cacheURL)
  }

  if turns {
    let classifier = try MLModel(contentsOf: MLModel.compileModel(at: model))
    for (i, print) in features.enumerated() {
      let output = try classifier.prediction(
        from: MLDictionaryFeatureProvider(dictionary: ["features": MLMultiArray(MLShapedArray<Float>(scalars: print, shape: [print.count]))]))
      let odds = output.featureValue(for: "labelProbability")?.dictionaryValue as? [String: Double] ?? [:]
      let mine = (0..<4).map { odds["\(labels[i])@\($0)"] ?? 0 }
      let total = mine.reduce(0, +)
      guard total > 0, let best = mine.indices.max(by: { mine[$0] < mine[$1] }) else { continue }
      Swift.print(files[i], best, mine[best] / total, separator: "\t")
    }
    exit(0)
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
