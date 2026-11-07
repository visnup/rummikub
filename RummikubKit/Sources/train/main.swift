#if os(macOS)
  import CreateML
  import Foundation
  import ImageIO
  import Vision

  // Trains a tile detector on the captures whose boxes are done (`boxed.txt`), writes it to `Tiles.mlmodel` beside
  // them, then draws its boxes into every other capture's `tiles.json` that hasn't been touched by hand, so each
  // round of checking boxes leaves less for the next. With another set (images and a Create ML `annotations.json`),
  // trains on that too and writes the model there instead, since it isn't ours to ship.
  //   train <captures> [<set>]
  let captures = URL(filePath: CommandLine.arguments[1])
  let extra = CommandLine.arguments.dropFirst(2).first.map { URL(filePath: $0) }
  let done = Set(
    ((try? String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8)) ?? "").split(separator: "\n")
      .map(String.init))

  func tiles(_ name: String) -> [[String: Any]] {
    let url = captures.appending(path: name + ".tiles.json")
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
  }

  // Create ML reads every image by its name in one directory, so link the done ones into a fresh one.
  let training = FileManager.default.temporaryDirectory.appending(path: "rummikub-training")
  try? FileManager.default.removeItem(at: training)
  try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
  var annotations = [[String: Any]]()
  for name in done.sorted() {
    let boxes = tiles(name).compactMap { $0["frame"] as? [Double] }
    guard !boxes.isEmpty else { continue }
    let file = name.replacingOccurrences(of: "/", with: "-") + ".png"
    try FileManager.default.createSymbolicLink(
      at: training.appending(path: file), withDestinationURL: captures.appending(path: name + ".png"))
    annotations.append([
      "image": file,
      "annotations": boxes.map { f in
        ["label": "tile", "coordinates": ["x": f[0], "y": f[1], "width": f[2], "height": f[3]]]
      },
    ])
  }
  if let extra {
    let data = try Data(contentsOf: extra.appending(path: "annotations.json"))
    for var entry in try JSONSerialization.jsonObject(with: data) as! [[String: Any]] {
      let file = "extra-" + (entry["image"] as! String)
      try FileManager.default.createSymbolicLink(
        at: training.appending(path: file), withDestinationURL: extra.appending(path: entry["image"] as! String))
      entry["image"] = file
      annotations.append(entry)
    }
  }
  let annotationFile = training.appending(path: "annotations.json")
  try JSONSerialization.data(withJSONObject: annotations).write(to: annotationFile)
  print("training on", annotations.count, "captures,", annotations.reduce(0) { $0 + ($1["annotations"] as! [Any]).count }, "tiles")

  // Stops at MINUTES (default 60) and keeps the last checkpoint.
  let deadline = Date(timeIntervalSinceNow: 60 * (Double(ProcessInfo.processInfo.environment["MINUTES"] ?? "") ?? 60))
  let job = try MLObjectDetector.train(
    trainingData: .directoryWithImages(at: training, annotationFile: annotationFile),
    annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .topLeft),
    parameters: .init(validation: .none, algorithm: .transferLearning(.objectPrint(revision: 1))),
    sessionParameters: .init(sessionDirectory: training.appending(path: "session"), reportInterval: 10, checkpointInterval: 50))
  nonisolated(unsafe) var result: Result<MLObjectDetector, Error>?
  nonisolated(unsafe) var checkpoint: MLCheckpoint?
  let subscriptions = [
    job.result.sink { @Sendable in if case .failure(let e) = $0 { result = .failure(e) } } receiveValue: { @Sendable in
      result = .success($0)
    },
    job.checkpoints.sink { @Sendable in checkpoint = $0 },
  ]
  while result == nil {
    Thread.sleep(forTimeInterval: 30)
    if let p = MLProgress(progress: job.progress) {
      print(
        p.phase, p.itemCount, "of", p.totalItemCount.map(String.init) ?? "?",
        (p.metrics[.loss] as? Double).map { "loss \($0)" } ?? "", "\(Int(p.elapsedTime))s")
    }
    if Date() > deadline, let last = checkpoint, last.phase == .training {
      job.cancel()
      print("out of time, keeping iteration", last.iteration)
      result = Result { try MLObjectDetector(checkpoint: last) }
    }
  }
  _ = subscriptions
  let detector = try result!.get()
  let modelURL = (extra ?? captures).appending(path: "Tiles.mlmodel")
  try detector.write(to: modelURL)
  // Through Vision, as the app will: MLObjectDetector.prediction's boxes are skewed on portrait images.
  let request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: MLModel.compileModel(at: modelURL))))
  request.imageCropAndScaleOption = .scaleFill

  let pngs = try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
    + ((try? FileManager.default.contentsOfDirectory(at: captures.appending(path: "unlabeled"), includingPropertiesForKeys: nil)) ?? [])
  for url in pngs.filter({ $0.pathExtension == "png" }).sorted(by: { $0.path < $1.path }) {
    let name = String(url.deletingPathExtension().path.dropFirst(captures.path.count + 1))
    let current = tiles(name)
    // Captures with no tiles in their truth keep their empty labels.
    let truth = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8))?
      .split(separator: "\n").dropFirst().joined()
    guard !done.contains(name), !current.contains(where: { $0["source"] as? String == "hand" }), truth != "" else {
      continue
    }
    try VNImageRequestHandler(url: url).perform([request])
    let found = (request.results as? [VNRecognizedObjectObservation] ?? []).filter { $0.confidence > 0.5 }
    let size = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
      as? [CFString: Any]
    let (w, h) = (size?[kCGImagePropertyPixelWidth] as! Int, size?[kCGImagePropertyPixelHeight] as! Int)
    // The model's box wins, but a value already read for it is kept. Confirmed tiles stay even when the model misses
    // them; unconfirmed ones go.
    var unmatched = current
    var merged = found.map { object -> [String: Any] in
      let n = VNImageRectForNormalizedRect(object.boundingBox, w, h)
      let b = CGRect(x: n.minX, y: Double(h) - n.maxY, width: n.width, height: n.height)
      var tile: [String: Any] = ["tile": "?", "turns": 0, "confirmed": false]
      if let i = unmatched.firstIndex(where: { overlap(frame($0), b) > 0.5 }) { tile = unmatched.remove(at: i) }
      tile["frame"] = [b.minX, b.minY, b.width, b.height]
      tile["source"] = "model"
      tile["confidence"] = object.confidence
      return tile
    }
    merged += unmatched.filter { $0["confirmed"] as? Bool == true }
    try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
      .write(to: captures.appending(path: name + ".tiles.json"))
    print(name, current.count, "→", merged.count, "boxes")
  }

  func frame(_ tile: [String: Any]) -> CGRect {
    let f = tile["frame"] as! [Double]
    return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
  }

  /// Intersection over union.
  func overlap(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let shared = i.width * i.height
    return shared / (a.width * a.height + b.width * b.height - shared)
  }
#endif
