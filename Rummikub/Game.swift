import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Observation
import RummikubKit
import UniformTypeIdentifiers

/// What the camera has read of the table and rack, the plays for them, and the step being shown.
@Observable final class Game {
  enum Looking: String, CaseIterable {
    case table, rack
  }

  /// What a capture writes as its truth: what was read, to be corrected by hand, or a layout set out on purpose.
  enum Layout: String, CaseIterable {
    case read = "As read", fullSet = "Full set", empty = "No tiles"

    var melds: [String]? {
      switch self {
      case .read: nil
      case .fullSet: "kkbboorr".map { color in (1...13).map { "\(color)\($0)" }.joined(separator: " ") } + ["j j"]
      case .empty: []
      }
    }
  }

  var looking = Looking.table
  var layout = Layout.read
  /// What's around the tiles, like "lamp glare, wood", saved with each capture.
  var notes = ""
  var gravity: [Double]?
  /// How long the last frame took to read: classifying the finder's boxes, or the reader without them.
  var readTime = Duration.zero
  /// How long the finder took on the last frame.
  var findTime = Duration.zero
  /// The tiles the finder saw in the last frame.
  var boxes = [CGRect]()
  private let finder = Game.model("Tiles").flatMap { try? Finder(model: $0) }
  /// What reads the finder's boxes: on the table at any quarter turn; on a rack, upright.
  private let classifiers = [Looking.table: "Values", .rack: "RackValues"].compactMapValues {
    Game.model($0).flatMap { try? Classifier(model: $0) }
  }
  /// Whether a frame shows a rack or the table, from the whole picture: tilt alone can't say, since racks were shot at
  /// 24–48° and tables from 35° up. On held-out frames it got 21 of 24, two of them judgment calls.
  private let rackOrTable = Game.model("RackOrTable").flatMap { try? Classifier(model: $0) }

  private static func model(_ name: String) -> MLModel? {
    let configuration = MLModelConfiguration()
    #if targetEnvironment(simulator)
      // Else Vision can't create an inference context.
      configuration.computeUnits = .cpuOnly
    #endif
    return Bundle.main.url(forResource: name, withExtension: "mlmodelc").flatMap {
      try? MLModel(contentsOf: $0, configuration: configuration)
    }
  }
  /// How far the camera points below the horizon, in degrees. Looking down at the table it's steep; at the rack,
  /// nearly level. Below 30° and above 55° it decides; between, the rack-or-table model does, or without it a cutoff at
  /// 45°. A pick by hand holds until the phone goes below 30° or above 70°.
  var tilt: Double? {
    didSet {
      guard let tilt else { return }
      if tilt > (picked == .rack ? 70 : 55) {
        looking = .table
        picked = nil
      } else if tilt < 30 {
        looking = .rack
        picked = nil
      } else if tilt < 45, picked == nil, rackOrTable == nil {
        looking = .rack
      }
    }
  }
  /// What was picked by hand, until the tilt overrides it.
  private var picked: Looking?

  func pick(_ looking: Looking) {
    self.looking = looking
    picked = looking
  }
  /// The last frame read, and what was read in it.
  var frame: CGImage?
  var detections = [Detection]()
  var scene = Scene(table: [], rack: [])
  var plays = [Play]()
  var choice = 0
  /// The step shown, or nil before starting a play. While stepping, new readings don't re-solve.
  var step: Int?
  /// Every frame's timing, a file a launch in Documents/timing, for `make timing`.
  private let timing: FileHandle? = {
    let directory = URL.documentsDirectory.appending(path: "timing")
    let url = directory.appending(path: Date.now.formatted(.iso8601) + ".csv")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: Data("time,looking,read_ms,find_ms,readings,boxes\n".utf8))
    else { return nil }
    return try? FileHandle(forWritingTo: url)
  }()

  var play: Play? { plays.indices.contains(choice) ? plays[choice] : nil }

  func see(_ image: CGImage) async {
    // Only where tilt can't say: below 30° it's always been a rack, above 55° a table.
    if picked == nil, let rackOrTable, (30...55).contains(tilt ?? 40),
      let (label, confidence) = await Task.detached(operation: { try? rackOrTable.label(of: image) }).value,
      confidence >= 0.8, let seen = Looking(rawValue: label)
    {
      looking = seen
    }
    let finder = finder, classifier = classifiers[looking]
    // The finder's boxes read by a classifier: on the held-out captures 435 of 572 tiles right with 79 extras, where
    // the reader got 345 with 93. Without the models, the reader.
    let (found, boxes, findTime, time) = await Task.detached {
      let clock = ContinuousClock()
      var boxes: [CGRect]?
      let findTime = clock.measure { boxes = try? finder?.tiles(in: image) }
      var found = [Detection]()
      let time = clock.measure {
        if let boxes, let classifier, let read = try? classifier.tiles(in: image, boxes: boxes) {
          found = read
        } else {
          found = Recognizer.tiles(in: image)
        }
      }
      return (found, boxes, findTime, time)
    }.value
    frame = image
    readTime = time
    self.findTime = findTime
    self.boxes = boxes ?? []
    detections = found
    _ = try? timing?.seekToEnd()
    try? timing?.write(contentsOf: Data(
      "\(Date.now.timeIntervalSince1970),\(looking),\(Int(time / .milliseconds(1))),\(Int(findTime / .milliseconds(1))),\(found.count),\(boxes?.count ?? -1)\n".utf8))
    let part = looking
    readings[part] = Array(((readings[part] ?? []) + [part == .rack ? onRack(found) : found]).suffix(5))
    let voted = vote(readings[part]!)
    var next = scene
    if part == .table {
      next.table = Recognizer.melds(voted)
    } else {
      next.rack = voted
    }

    if let play, let step, part == .table {
      let done = play.stepsDone(next.tableTiles, from: scene.tableTiles)
      if done == play.steps.count {
        // The play is on the table: take the table as it now reads, and the rack without what came from it.
        let used = Set(play.steps.compactMap { if case .rack(let i) = $0.from { i } else { nil } })
        scene = Scene(table: next.table, rack: scene.rack.indices.filter { !used.contains($0) }.map { scene.rack[$0] })
        self.step = nil
        await solve()
      } else if done > step {
        self.step = done
      }
      return
    }

    let same = next.tiles(part) == scene.tiles(part)
    if same {
      changedSince[part] = nil
      // Frames follow the tiles as the camera moves, but a reordering would break a play's indices.
      if next.reads(like: scene) { scene = next }
      let since = steadySince[part] ?? .now
      steadySince[part] = since
      if !locked.contains(part), Date.now.timeIntervalSince(since) >= 2,
        part == .table || !voted.isEmpty
      {
        locked.insert(part)
        await solve()
      }
    } else if locked.contains(part) {
      changedSince[part] = changedSince[part] ?? .now
    } else {
      scene = next
      steadySince[part] = .now
    }
  }

  /// Each part's last few frames' readings, newest last.
  private var readings = [Looking: [[Detection]]]()
  /// When each part's reading last changed while scanning.
  private var steadySince = [Looking: Date]()
  /// When a locked part's reading started disagreeing with it.
  private var changedSince = [Looking: Date]()
  /// The parts whose reading has held for two seconds; frames no longer change them, until `rescan`.
  var locked = Set<Looking>()

  /// Whether a locked part has read differently for three seconds, as after someone's turn.
  func changed(_ part: Looking) -> Bool { changedSince[part].map { Date.now.timeIntervalSince($0) >= 3 } ?? false }

  /// Scans a part again, from scratch.
  func rescan(_ part: Looking) {
    locked.remove(part)
    readings[part] = nil
    changedSince[part] = nil
    steadySince[part] = .now
  }

  /// Readings by vote: each tile as many times as the median frame read it, since a frame often misses or misreads a
  /// tile or two of 14, and two frames rarely agree exactly.
  private func vote(_ readings: [[Detection]]) -> [Detection] {
    Set(readings.joined().map(\.tile)).sorted { $0.description < $1.description }.flatMap { tile in
      let counts = readings.map { $0.count { $0.tile == tile } }.sorted()
      let copies = counts[counts.count / 2]
      let seen = readings.last { $0.count { $0.tile == tile } >= copies } ?? []
      return seen.filter { $0.tile == tile }.prefix(copies)
    }
  }

  /// The rack's tiles. Tiles under a third of the tallest one's height are the table behind it: in rack captures those
  /// were 18–37 px tall, and the rack's 52 and up, but for one mostly hidden behind another. And the rack's two rows
  /// lie within a tile or so of its five tallest tiles, so anything farther above or below is something else.

  private func onRack(_ found: [Detection]) -> [Detection] {
    let tall = found.sorted { $0.frame.height > $1.frame.height }.prefix(5)
    let tallest = tall.first?.frame.height ?? 0
    let ys = tall.map(\.frame.midY).sorted()
    let middle = ys.isEmpty ? 0 : ys[ys.count / 2]
    return found.filter { $0.frame.height >= tallest / 3 && abs($0.frame.midY - middle) <= tallest * 1.5 }
  }

  /// What the last frame read that agrees with the settled table or rack, whichever is being looked at, so the
  /// Solver labels only those.
  var settled: [Detection] {
    var left = looking == .table ? scene.tableTiles.flatMap { $0 } : scene.rackTiles
    return (looking == .table ? detections : onRack(detections)).filter { detection in
      guard let i = left.firstIndex(of: detection.tile) else { return false }
      left.remove(at: i)
      return true
    }
  }

  /// Saves the last frame to Documents as `<time>.png`, its truth as `<time>.txt` (what it was looking at, then a meld
  /// a line), and everything else known about it as `<time>.json`, to become test fixtures. PNG, so the fixture is the
  /// same pixels the phone read.
  func capture(camera: [String: Any]) {
    guard let frame else { return }
    let base = URL.documentsDirectory.appending(path: Date.now.formatted(.iso8601))
    let destination = CGImageDestinationCreateWithURL(
      base.appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, frame, nil)
    CGImageDestinationFinalize(destination)
    let read = Recognizer.melds(detections).map { $0.map(\.tile.description).joined(separator: " ") }
    let tilt = tilt.map { " \(Int($0))°" } ?? ""
    try? (looking.rawValue + tilt + "\n" + (layout.melds ?? read).map { $0 + "\n" }.joined())
      .write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    let info: [String: Any] = [
      "looking": looking.rawValue, "layout": layout.rawValue, "notes": notes, "tilt": self.tilt ?? NSNull(),
      "gravity": gravity ?? [], "readMilliseconds": readTime / .milliseconds(1),
      "findMilliseconds": findTime / .milliseconds(1), "camera": camera, "read": read,
      "boxes": boxes.map { [$0.minX, $0.minY, $0.width, $0.height] },
      "detections": detections.map {
        ["tile": $0.tile.description, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]]
      },
    ]
    try? JSONSerialization.data(withJSONObject: finite(info), options: [.prettyPrinted, .sortedKeys])
      .write(to: base.appendingPathExtension("json"))
  }

  func solve() async {
    let table = scene.tableTiles, rack = scene.rackTiles
    plays = await Task.detached { RummikubKit.solve(table: table, rack: rack) }.value
    choice = max(0, plays.count - 1)
  }

  /// What to draw for the current step. The rack is never in the same frame as the table, so a tile from it can't be
  /// pointed at.
  var marks: [Mark] {
    guard let play, let step, play.steps.indices.contains(step) else { return [] }
    let tile = play.steps[step].tile
    if looking == .rack {
      guard case .rack = play.steps[step].from, let match = detections.first(where: { $0.tile == tile }) else {
        return []
      }
      return [.source(match.frame)]
    }
    let marks = play.marks(in: scene.following(detections), step: step)
    guard case .rack = play.steps[step].from else { return marks }
    return marks.filter {
      switch $0 {
      case .source, .arrow: false
      default: true
      }
    }
  }
}

/// The value with NaN and infinities as null, which JSONSerialization throws on, crashing the app.
private func finite(_ value: Any) -> Any {
  switch value {
  case let dictionary as [String: Any]: dictionary.mapValues(finite)
  case let array as [Any]: array.map(finite)
  case let n as Double where !n.isFinite: NSNull()
  case let n as Float where !n.isFinite: NSNull()
  case let n as CGFloat where !n.isFinite: NSNull()
  default: value
  }
}

extension Scene {
  func reads(like other: Scene) -> Bool { tableTiles == other.tableTiles && rackTiles == other.rackTiles }

  /// A part's tiles in no order.
  func tiles(_ part: Game.Looking) -> [String] {
    (part == .table ? tableTiles.flatMap { $0 } : rackTiles).map(\.description).sorted()
  }
}
