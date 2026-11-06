import CoreGraphics
import Observation
import RummikubKit

/// What the camera has read of the table and rack, the plays for them, and the step being shown.
@Observable final class Game {
  enum Looking: String, CaseIterable {
    case table, rack
  }

  var looking = Looking.table
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
  /// Whether the table and rack came from one image, as in the demo.
  private var together = false

  var play: Play? { plays.indices.contains(choice) ? plays[choice] : nil }

  /// Reads `image`. With `rackY`, the image holds both the table and, below that line, the rack.
  func see(_ image: CGImage, rackY: CGFloat? = nil) async {
    let found = await Task.detached { Recognizer.tiles(in: image) }.value
    frame = image
    detections = found
    var next = scene
    if let rackY {
      next = Scene(found, rackY: rackY)
    } else if looking == .table {
      next.table = Recognizer.melds(found)
    } else {
      next.rack = Recognizer.melds(found).flatMap { $0 }
    }
    together = rackY != nil
    if let play, let step, rackY != nil || looking == .table {
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

  func solve() async {
    let table = scene.tableTiles, rack = scene.rackTiles
    plays = await Task.detached { RummikubKit.solve(table: table, rack: rack) }.value
    choice = max(0, plays.count - 1)
  }

  /// What to draw for the current step. Unless the rack was read in the same frame as the table, a tile from it
  /// can't be pointed at.
  var marks: [Mark] {
    guard let play, let step, play.steps.indices.contains(step) else { return [] }
    let marks = play.marks(in: scene.following(detections), step: step)
    guard case .rack = play.steps[step].from, !together else { return marks }
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
