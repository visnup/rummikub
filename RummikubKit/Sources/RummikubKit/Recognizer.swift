import CoreGraphics

extension CGRect {
  /// From `[x, y, width, height]`, as captures, labels and logs write boxes.
  public init(xywh f: [Double]) { self.init(x: f[0], y: f[1], width: f[2], height: f[3]) }
  public var xywh: [Double] { [minX, minY, width, height] }
}

public struct Detection: Hashable, Sendable {
  public let tile: Tile
  /// In top-left-origin pixels.
  public let frame: CGRect
  /// Its orientation: how many quarter turns clockwise make it upright.
  public var turns = 0
  /// How likely each tile is, from the classifier, for `Recognizer.valid` to weigh other readings by.
  public var odds = [Tile: Float]()
  /// The same at each orientation, from a classifier whose classes are tiles at an orientation.
  public var turned = [Tile: [Float]]()
  /// How likely it stands on a rack rather than lies on the table, from a classifier that says.
  public var rack: Float?
  /// Where a rack tile stands along the rack, in metres, as `World` measured it.
  public var along: Float?

  public init(
    tile: Tile, frame: CGRect, turns: Int = 0, odds: [Tile: Float] = [:], turned: [Tile: [Float]] = [:], rack: Float? = nil
  ) {
    self.tile = tile
    self.frame = frame
    self.turns = turns
    self.odds = odds
    self.turned = turned
    self.rack = rack
  }
}

/// What the readings of a frame say together: which tiles lie in a meld, which way they face, and which valid melds
/// they likeliest are.
public enum Recognizer {
  /// Tiles side by side in the same row, in reading order.
  public static func melds(_ detections: [Detection]) -> [[Detection]] {
    var melds = [[Detection]]()
    for detection in detections.sorted(by: { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }) {
      let frame = detection.frame
      if let i = melds.firstIndex(where: {
        let last = $0.last!.frame
        return abs(last.midY - frame.midY) < frame.height / 3 && abs(frame.minX - last.maxX) < frame.width / 3
      }) {
        melds[i].append(detection)
      } else {
        melds.append([detection])
      }
    }
    return melds.sorted {
      abs($0[0].frame.midY - $1[0].frame.midY) < $0[0].frame.height / 2
        ? $0[0].frame.minX < $1[0].frame.minX : $0[0].frame.midY < $1[0].frame.midY
    }
  }
}
