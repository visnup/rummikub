#if os(macOS)
  import CreateML
  import Foundation
  import ImageIO
  import RummikubKit

  // Trains a tile detector on the captures whose boxes are done (`boxed.txt`), except the held-out ones, and writes it
  // to `Tiles.mlmodel` beside them. Other folders add every photo (.jpg) in them that has a `.tiles.json`, like the
  // outside sets `Labeler/outside.py` converts.
  //   train <captures> [<folder>...]
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let outside = CommandLine.arguments.dropFirst(2).map { URL(filePath: $0) }
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
  let held = done.filter(Finder.isHeldOut)
  var annotations = [[String: Any]]()
  /// Adds the image and its crops, so tiles small in a photo are large in some crop. A crop keeps only the tiles
  /// wholly inside it.
  @MainActor func add(_ source: URL, as file: String, boxes: [CGRect]) throws {
    func annotation(_ file: String, _ boxes: [CGRect]) -> [String: Any] {
      let coordinates = boxes.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
      return ["image": file, "annotations": coordinates.map { ["label": "tile", "coordinates": $0] }]
    }
    try FileManager.default.createSymbolicLink(at: training.appending(path: file), withDestinationURL: source)
    annotations.append(annotation(file, boxes))
    let image = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
    for (i, crop) in Finder.crops(width: image.width, height: image.height, overlap: false).enumerated() {
      let inside = boxes.filter { crop.contains($0) }.map { $0.offsetBy(dx: -crop.minX, dy: -crop.minY) }
      guard !inside.isEmpty else { continue }
      let name = "\(file)-\(i).jpg"
      let destination = CGImageDestinationCreateWithURL(
        training.appending(path: name) as CFURL, "public.jpeg" as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, image.cropping(to: crop)!, nil)
      CGImageDestinationFinalize(destination)
      annotations.append(annotation(name, inside))
    }
  }
  // QUARTERS (default 4) trains on that many quarters of the captures, nested, for a learning curve.
  let quarters = Int(ProcessInfo.processInfo.environment["QUARTERS"] ?? "") ?? 4
  for (i, name) in done.subtracting(held).sorted().enumerated() where i % 4 < quarters {
    let boxes = tiles(name).map(frame)
    guard !boxes.isEmpty else { continue }
    try add(
      captures.appending(path: name + ".png"), as: name.replacingOccurrences(of: "/", with: "-") + ".png", boxes: boxes)
  }
  for folder in outside {
    for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    where url.pathExtension == "jpg" {
      let labels = url.deletingPathExtension().appendingPathExtension("tiles.json")
      let boxes = try (JSONSerialization.jsonObject(with: Data(contentsOf: labels)) as! [[String: Any]]).map(frame)
      try add(url, as: folder.lastPathComponent + "-" + url.lastPathComponent, boxes: boxes)
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
    // ITERATIONS (default 1000, Create ML's own) for more data than ours alone.
    sessionParameters: .init(
      sessionDirectory: training.appending(path: "session"), reportInterval: 10, checkpointInterval: 50,
      iterations: Int(ProcessInfo.processInfo.environment["ITERATIONS"] ?? "") ?? 1000))
  nonisolated(unsafe) var result: Result<MLObjectDetector, Error>?
  nonisolated(unsafe) var checkpoint: MLCheckpoint?
  let subscriptions = [
    job.result.sink { @Sendable in if case .failure(let e) = $0 { result = .failure(e) } } receiveValue: { @Sendable in
      result = .success($0)
    },
    job.checkpoints.sink { @Sendable in checkpoint = $0 },
  ]
  while result == nil {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
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
  try detector.write(to: captures.appending(path: "Tiles.mlmodel"))

  func frame(_ tile: [String: Any]) -> CGRect {
    let f = tile["frame"] as! [Double]
    return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
  }
#endif
