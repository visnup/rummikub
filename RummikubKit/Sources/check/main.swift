#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Lists where the models disagree with each done capture's labels, for the labeler to show: boxes the finder
  // doesn't find, boxes it finds that aren't labeled, and confirmed values that Values reads as
  // another tile at least .8 sure. Training captures too, since a label the models can't fit is likely wrong.
  // Captures checked go in `.check.done`; with --new, only done captures not there yet are checked, so `make watch`
  // can run it every pass.
  //   check [--new] <captures>  → <captures>/.check.json
  setvbuf(stdout, nil, _IOLBF, 0)
  let new = CommandLine.arguments.contains("--new")
  let captures = URL(filePath: CommandLine.arguments.dropFirst().first { $0 != "--new" }!)
  let checkedURL = captures.appending(path: ".check.done"), outURL = captures.appending(path: ".check.json")
  let done = try String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8).split(separator: "\n")
    .map(String.init)
  let checked = new ? Set(((try? String(contentsOf: checkedURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)) : []
  let todo = done.filter { !checked.contains($0) }
  if todo.isEmpty { exit(0) }

  let tiles = try MLModel.compileModel(at: captures.appending(path: "Tiles.mlpackage"))
  let classes = try MLModel.compileModel(at: captures.appending(path: "Values.mlpackage"))
  func array(_ r: CGRect) -> [Double] { r.xywh.map { ($0 * 10).rounded() / 10 } }

  // The labeler's numbers: line numbers in ids.txt.
  let ids = Dictionary(
    ((try? String(contentsOf: captures.appending(path: "ids.txt"), encoding: .utf8)) ?? "").split(separator: "\n")
      .enumerated().map { (String($1), $0 + 1) }, uniquingKeysWith: { a, _ in a })

  // Guarded by `lock`.
  nonisolated(unsafe) var out =
    new ? (try? JSONSerialization.jsonObject(with: Data(contentsOf: outURL))) as? [String: Any] ?? [:] : [:]
  nonisolated(unsafe) var n = 0
  let lock = NSLock()
  print("checked", "#", "missed", "extra", "values", separator: "\t")
  // Each worker its own models, since a Vision request isn't safe to share.
  // 2 took 24 s for 194 captures, 4 and 8 22 s, against 31 s for one.
  let workers = min(4, todo.count)
  DispatchQueue.concurrentPerform(iterations: workers) { worker in
    let finder = try! Finder(model: MLModel(contentsOf: tiles))
    let values = try! Classifier(model: MLModel(contentsOf: classes))
    for name in todo[worker...].enumerated().filter({ $0.offset % workers == 0 }).map(\.element) {
      try! check(name, finder, values)
    }
  }

  func check(_ name: String, _ finder: Finder, _ values: Classifier) throws {
    let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let truth = labels.map { CGRect(xywh: $0["frame"] as! [Double]) }

    var left = Array(truth.indices), extra = [[Double]]()
    for box in try finder.tiles(in: image) {
      if let i = left.max(by: { Finder.overlap(truth[$0], box) < Finder.overlap(truth[$1], box) }),
        Finder.overlap(truth[i], box) > 0.5
      {
        left.removeAll { $0 == i }
      } else {
        extra.append(array(box))
      }
    }

    let confirmed = labels.indices.filter { labels[$0]["confirmed"] as? Bool == true && Tile(labels[$0]["tile"] as! String) != nil }
    let reads = try values.tiles(in: image, boxes: confirmed.map { truth[$0] }, least: 0.8)
    var misread = [[String: Any]]()
    for i in confirmed {
      guard let read = reads.first(where: { $0.frame == truth[i] }) else { continue }
      if read.tile.description != labels[i]["tile"] as! String {
        misread.append(["frame": array(truth[i]), "tile": labels[i]["tile"]!, "read": read.tile.description,
          "odds": (read.odds[read.tile]! * 100).rounded() / 100])
      }
    }
    // A box on a tile out of scope isn't extra, nor is one the finder misses there missed.
    left.removeAll { !Finder.inScope(truth[$0], width: image.width, height: image.height) }
    lock.withLock {
      out[name] = !left.isEmpty || !extra.isEmpty || !misread.isEmpty
        ? ["missed": left.map { array(truth[$0]) }, "extra": extra, "values": misread] : nil
      n += 1
      let id = ids[String(name.split(separator: "/").last!)].map { "#\($0)" } ?? name
      print("\(n)/\(todo.count)", id, left.count, extra.count, misread.count, separator: "\t")
    }
  }
  // Every done capture by each tag in its notes, flagged or not.
  var tagged = [String: [String]]()
  for name in done {
    let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".json")))) as? [String: Any]
    for tag in ((info?["notes"] as? String) ?? "").split(whereSeparator: \.isWhitespace) { tagged[String(tag), default: []].append(name) }
  }
  print("\ntag", "captures", "flagged", "missed", "extra", "values", separator: "\t")
  for (tag, names) in tagged.sorted(by: { $0.key < $1.key }) {
    let flags = names.compactMap { out[$0] as? [String: [Any]] }
    let sum = { (key: String) in flags.reduce(0) { $0 + $1[key]!.count } }
    print(tag, names.count, flags.count, sum("missed"), sum("extra"), sum("values"), separator: "\t")
  }
  try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: outURL)
  try (checked.union(todo).sorted().joined(separator: "\n") + "\n").write(to: checkedURL, atomically: true, encoding: .utf8)
#endif
