#if os(macOS)
  import CreateML
  import Foundation
  import ImageIO
  import RummikubKit
  import Vision

  // Trains a tile detector on the captures whose boxes are done (`boxed.txt`), writes it to `Tiles.mlmodel` beside
  // them, then draws its boxes into every other capture's `tiles.json` that hasn't been touched by hand, so each
  // round of checking boxes leaves less for the next. With another set (images and a Create ML `annotations.json`),
  // trains on that too and writes the model there instead, since it isn't ours to ship.
  //   train <captures> [<set>]
  setvbuf(stdout, nil, _IOLBF, 0)
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
  // Every fifth done capture is held out to score the model.
  let held = Set(done.sorted().enumerated().filter { $0.offset % 5 == 4 }.map(\.element))
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
  for name in done.subtracting(held).sorted() {
    let boxes = tiles(name).map(frame)
    guard !boxes.isEmpty else { continue }
    try add(
      captures.appending(path: name + ".png"), as: name.replacingOccurrences(of: "/", with: "-") + ".png", boxes: boxes)
  }
  if let extra {
    let data = try Data(contentsOf: extra.appending(path: "annotations.json"))
    for entry in try JSONSerialization.jsonObject(with: data) as! [[String: Any]] {
      let image = entry["image"] as! String
      let boxes = (entry["annotations"] as! [[String: Any]]).map {
        let c = $0["coordinates"] as! [String: Double]
        return CGRect(x: c["x"]!, y: c["y"]!, width: c["width"]!, height: c["height"]!)
      }
      try add(extra.appending(path: image), as: "extra-" + image, boxes: boxes)
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
  let modelURL = (extra ?? captures).appending(path: "Tiles.mlmodel")
  try detector.write(to: modelURL)
  // Through Vision, as the app does: MLObjectDetector.prediction's boxes are skewed on portrait images.
  let finder = try Finder(model: MLModel(contentsOf: MLModel.compileModel(at: modelURL)))
  func detect(_ url: URL) throws -> [(box: CGRect, confidence: Float)] {
    try finder.tiles(in: CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!)
  }

  var (total, hits, extras) = (0, 0, 0)
  for name in held.sorted() {
    var truth = tiles(name).map(frame)
    var extra = 0
    for (box, _) in try detect(captures.appending(path: name + ".png")) {
      if let i = truth.indices.max(by: { overlap(truth[$0], box) < overlap(truth[$1], box) }),
        overlap(truth[i], box) > 0.5
      {
        truth.remove(at: i)
      } else {
        extra += 1
      }
    }
    let count = tiles(name).count
    print("held out", name, "found", count - truth.count, "of", count, "with", extra, "extra")
    (total, hits, extras) = (total + count, hits + count - truth.count, extras + extra)
  }
  print("held out: found", hits, "of", total, "tiles, with", extras, "extra boxes")

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
    let found = try detect(url)
    // The model's box wins, but a value already read for it is kept. Confirmed tiles stay where the model found
    // nothing; unconfirmed ones go. The reader's boxes are guessed from the numeral, so any overlap is a match.
    var unmatched = current
    var merged = found.map { (b, confidence) -> [String: Any] in
      var tile: [String: Any] = ["tile": "?", "turns": 0, "confirmed": false]
      if let i = unmatched.indices.max(by: { overlap(frame(unmatched[$0]), b) < overlap(frame(unmatched[$1]), b) }),
        overlap(frame(unmatched[i]), b) > 0
      {
        tile = unmatched.remove(at: i)
      }
      tile["frame"] = [b.minX, b.minY, b.width, b.height]
      tile["source"] = "model"
      tile["confidence"] = confidence
      return tile
    }
    merged += unmatched.filter { t in
      t["confirmed"] as? Bool == true && !found.contains { overlap(frame(t), $0.box) > 0 }
    }
    try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
      .write(to: captures.appending(path: name + ".tiles.json"))
    print(name, current.count, "→", merged.count, "boxes")
  }

  func frame(_ tile: [String: Any]) -> CGRect {
    let f = tile["frame"] as! [Double]
    return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
  }

  func overlap(_ a: CGRect, _ b: CGRect) -> Double { Finder.overlap(a, b) }
#endif
