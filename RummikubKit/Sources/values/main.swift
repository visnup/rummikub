#if os(macOS)
  import CreateML
  import Foundation

  // Trains an image classifier on folders of crops named by their class, as `Labeler/crops.py` writes them. Through a
  // training session: `MLImageClassifier(trainingData:)` failed past a few thousand images with "Failed to create
  // CVPixelBufferPool", while the session extracts features in batches.
  //   values <crops> <model>
  setvbuf(stdout, nil, _IOLBF, 0)
  let crops = URL(filePath: CommandLine.arguments[1]), model = URL(filePath: CommandLine.arguments[2])
  let session = FileManager.default.temporaryDirectory.appending(path: "rummikub-values")
  try? FileManager.default.removeItem(at: session)
  let job = try MLImageClassifier.train(
    // No augmentation: the default's flips mirror numerals, and validation fell from 96% to 78%.
    trainingData: .labeledDirectories(at: crops),
    parameters: .init(validation: .split(strategy: .automatic), augmentation: []),
    sessionParameters: .init(sessionDirectory: session, reportInterval: 1000, checkpointInterval: 5000))
  nonisolated(unsafe) var result: Result<MLImageClassifier, Error>?
  let subscription = job.result.sink { @Sendable in if case .failure(let e) = $0 { result = .failure(e) } } receiveValue: {
    @Sendable in result = .success($0)
  }
  while result == nil {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
    if let p = MLProgress(progress: job.progress) { print(p.phase, p.itemCount, "of", p.totalItemCount.map(String.init) ?? "?") }
  }
  _ = subscription
  let classifier = try result!.get()
  print("validation accuracy", 1 - classifier.validationMetrics.classificationError)
  try classifier.write(to: model)
#endif
