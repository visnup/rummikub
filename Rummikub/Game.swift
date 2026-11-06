import CoreGraphics
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
  /// How long the last frame took to read.
  var readTime = Duration.zero
  /// How far the camera points below the horizon, in degrees. Looking down at the table it's steep; at the rack,
  /// nearly level. The gap between the two cutoffs keeps it from flipping back and forth.
  var tilt: Double? {
    didSet {
      guard let tilt else { return }
      if tilt > 50 { looking = .table } else if tilt < 35 { looking = .rack }
    }
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

  var play: Play? { plays.indices.contains(choice) ? plays[choice] : nil }

  func see(_ image: CGImage) async {
    let (found, time) = await Task.detached {
      var found = [Detection]()
      let time = ContinuousClock().measure { found = Recognizer.tiles(in: image) }
      return (found, time)
    }.value
    frame = image
    readTime = time
    detections = found
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
      "gravity": gravity ?? [], "readMilliseconds": readTime / .milliseconds(1), "camera": camera, "read": read,
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
