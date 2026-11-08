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
  /// nearly level. Without the rack-or-table model, it decides: the cutoffs leave a gap that keeps it from flipping
  /// back and forth. Either way, a pick by hand holds until the phone goes well past the other cutoff.
  var tilt: Double? {
    didSet {
      guard let tilt else { return }
      if tilt > (picked == .rack ? 70 : 55) {
        if picked != nil || rackOrTable == nil { looking = .table }
        picked = nil
      } else if tilt < (picked == .table ? 30 : 45) {
        if picked != nil || rackOrTable == nil { looking = .rack }
        picked = nil
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
  /// A reading that differs from `scene`, kept until a second frame agrees with it.
  private var pending: Scene?
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
    if picked == nil, let rackOrTable,
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
    var next = scene
    if looking == .table {
      next.table = Recognizer.melds(found)
    } else {
      next.rack = Recognizer.melds(found).flatMap { $0 }
    }
    if let play, let step, looking == .table {
      let done = play.stepsDone(next.tableTiles, from: scene.tableTiles)
      if done == play.steps.count {
        self.step = nil
      } else if done > step {
        self.step = done
      }
    }
    if next.reads(like: scene) {
      // Frames follow the tiles as the camera moves, even mid-play.
      scene = next
    } else if step == nil, let pending, next.reads(like: pending) {
      scene = next
      self.pending = nil
      await solve()
    } else if step == nil {
      pending = next
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
    try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
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

extension Scene {
  func reads(like other: Scene) -> Bool { tableTiles == other.tableTiles && rackTiles == other.rackTiles }
}
