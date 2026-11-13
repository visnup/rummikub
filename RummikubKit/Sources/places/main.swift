#if os(macOS)
  import Foundation
  import RummikubKit
  import simd

  // Replays each AR recording whose captures have boxes marked by hand, and scores how its places are told rack or
  // table against those marks: by Values' odds (`Place.isRack`) and by the game's rules (`World.parts`, knowing what
  // the app showed). Each marked place's features and mark go to `<captures>/.places.tsv`, to train on.
  //   places <captures>
  let captures = URL(filePath: CommandLine.arguments[1])
  let folders = [captures, captures.appending(path: "unlabeled")]
  func json(_ url: URL) -> Any? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
  /// A frame's boxes, which a capture taken from it shares.
  func key(_ frames: [CGRect]) -> String { frames.prefix(4).map { "\(Int($0.minX)),\(Int($0.minY))" }.joined(separator: " ") }

  // Each recording's hand-marked captures, by their frame's boxes.
  var marked = [String: [String: [(frame: CGRect, rack: Bool)]]]()
  for folder in folders {
    for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".tiles.json") {
      guard let notes = json(url) as? [String: Any], let recording = notes["recording"] as? String,
        let detections = notes["detections"] as? [[String: Any]],
        let tiles = json(url.deletingPathExtension().appendingPathExtension("tiles.json")) as? [[String: Any]]
      else { continue }
      let hand = tiles.filter { $0["confirmed"] as? Bool == true || $0["source"] as? String == "hand" }
      guard !hand.isEmpty else { continue }
      marked[recording, default: [:]][key(detections.map { CGRect(xywh: $0["frame"] as! [Double]) })] =
        hand.map { (CGRect(xywh: $0["frame"] as! [Double]), $0["rack"] as? Bool == true) }
    }
  }

  struct Score {
    var rack = 0, table = 0, valuesRack = 0, valuesTable = 0, rulesRack = 0, rulesTable = 0
    var description: String {
      "\(rack) rack, \(table) table; Values \(valuesRack)/\(rack) rack +\(valuesTable) table; "
        + "rules \(rulesRack)/\(rack) rack +\(rulesTable) table"
    }
  }
  var rows = ["recording\ttile\track\tseen\todds\theight\tmotion\tdistance\tdown\ttall\twidth"]
  var total = Score()
  for (recording, captured) in marked.sorted(by: { $0.key < $1.key }) {
    guard
      let log = folders.map({ $0.appending(path: recording + ".jsonl") })
        .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let frames = try? Recording(contentsOf: log).frames, let first = frames.first
    else {
      print(recording, "no log", separator: "\t")
      continue
    }
    var world = World(), votes = [Int: (rack: Int, table: Int)](), last: Pose?
    var before = first.shown ?? Scene(), previous = first.time, score = Score(), used = 0
    /// Scores the world's marked places as the last pose sees them, before it starts over.
    func tally() {
      guard let last else { return }
      let rack = world.parts(from: last, knowing: before).rack.map(\.frame)
      let camera = SIMD3(last.transform.columns.3.x, last.transform.columns.3.y, last.transform.columns.3.z)
      for (place, detection) in world.detections(from: last) {
        guard let v = votes[place.id], v.rack != v.table else { continue }
        let isRack = v.rack > v.table, byRules = rack.contains(detection.frame)
        if isRack {
          score.rack += 1
          if place.isRack { score.valuesRack += 1 }
          if byRules { score.rulesRack += 1 }
        } else {
          score.table += 1
          if place.isRack { score.valuesTable += 1 }
          if byRules { score.rulesTable += 1 }
        }
        let rise = world.rise(of: place, from: last), d = distance(camera, place.point)
        let turned = place.turns.indices.max { place.turns[$0] < place.turns[$1] }! % 2 == 1
        rows.append([recording, place.tile.description, isRack ? "1" : "0", "\(place.seen)",
          String(format: "%.3f", place.onRack ?? 0), String(format: "%.4f", rise?.height ?? 0),
          String(format: "%.4f", rise?.motion ?? 0), String(format: "%.3f", d),
          String(format: "%.3f", (camera.y - place.point.y) / d), String(format: "%.3f", turned ? 1 / place.aspect : place.aspect),
          String(format: "%.4f", place.width)].joined(separator: "\t"))
      }
      votes = [:]
    }
    for frame in frames {
      if frame.time - previous > 2, frame.tracking != "normal" { before = frame.shown ?? before }
      previous = frame.time
      // As the app does: a new world when ARKit starts one.
      if frame.tracking.contains("initializing"), !world.places.isEmpty {
        tally()
        world = World()
      }
      guard frame.tracking == "normal", frame.pose.plane != nil else { continue }
      let ids = world.add(frame.detections, pose: frame.pose, mask: frame.mask)
      last = frame.pose
      guard let marks = captured[key(frame.detections.map(\.frame))] else { continue }
      used += 1
      for (d, id) in zip(frame.detections, ids) {
        guard let id, let mark = marks.max(by: { Finder.overlap($0.frame, d.frame) < Finder.overlap($1.frame, d.frame) }),
          Finder.overlap(mark.frame, d.frame) > 0.5
        else { continue }
        if mark.rack { votes[id, default: (0, 0)].rack += 1 } else { votes[id, default: (0, 0)].table += 1 }
      }
    }
    tally()
    print(recording, "\(used) of \(captured.count) marked captures matched", score.description, separator: "\t")
    total.rack += score.rack
    total.table += score.table
    total.valuesRack += score.valuesRack
    total.valuesTable += score.valuesTable
    total.rulesRack += score.rulesRack
    total.rulesTable += score.rulesTable
  }
  print("total", total.description, separator: "\t")
  try rows.joined(separator: "\n").appending("\n").write(to: captures.appending(path: ".places.tsv"), atomically: true, encoding: .utf8)
#endif
