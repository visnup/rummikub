import CoreGraphics

/// What the camera has seen: the table's melds in the order `solve` gets them, and the rack.
public struct Scene: Sendable {
  public var table: [[Detection]]
  public var rack: [Detection]

  public init(table: [[Detection]], rack: [Detection]) {
    self.table = table
    self.rack = rack
  }

  /// Splits detections into the rack, below `rackY`, and the table's melds above it.
  public init(_ detections: [Detection], rackY: CGFloat) {
    table = Recognizer.melds(detections.filter { $0.frame.midY < rackY })
    rack = detections.filter { $0.frame.midY >= rackY }.sorted { $0.frame.minX < $1.frame.minX }
  }

  public var tableTiles: [[Tile]] { table.map { $0.map(\.tile) } }
  public var rackTiles: [Tile] { rack.map(\.tile) }
}

/// One thing to draw over the camera image, in its pixels.
public enum Mark: Hashable, Sendable {
  /// The tile to pick up.
  case source(CGRect)
  /// Where it goes, with the tile drawn as a ghost.
  case target(CGRect, Tile)
  case arrow(from: CGPoint, to: CGPoint)
  /// "Step 2 of 5" and the like.
  case caption(String)
}

extension Play {
  /// Where every tile of every new meld sits on the table: kept tiles where they are, the rest in line with them, and
  /// melds with no anchor in a new row under the table.
  public func slots(in scene: Scene) -> [[CGRect]] {
    let all = scene.table.joined().map(\.frame)
    let size = all.first?.size ?? scene.rack.first?.frame.size ?? CGSize(width: 60, height: 84)
    let pitch = size.width + 2
    var free = CGPoint(x: all.map(\.minX).min() ?? 0, y: (all.map(\.maxY).max() ?? 0) + size.height / 3)
    return melds.indices.map { n in
      let tiles = melds[n].tiles
      if let anchor = melds[n].anchor {
        let old = scene.table[anchor]
        let pairs = tiles.indices.compactMap { i in old.firstIndex { $0.tile == tiles[i] }.map { (i, old[$0].frame) } }
        if let (i, frame) = pairs.first {
          return tiles.indices.map { frame.offsetBy(dx: CGFloat($0 - i) * pitch, dy: 0) }
        }
      }
      let origin = free
      free.x += CGFloat(tiles.count) * pitch + size.width / 2
      return tiles.indices.map { CGRect(origin: CGPoint(x: origin.x + CGFloat($0) * pitch, y: origin.y), size: size) }
    }
  }

  /// What to draw for step `index`: the tile to pick up, where it goes, and an arrow between.
  public func marks(in scene: Scene, step index: Int) -> [Mark] {
    let step = steps[index]
    let source: CGRect =
      switch step.from {
      case .rack(let i): scene.rack[i].frame
      case .table(let meld, let i): scene.table[meld][i].frame
      }
    let slots = slots(in: scene)
    let earlier = steps[..<index].filter { $0.to == step.to && $0.tile == step.tile }.count
    let positions = melds[step.to].tiles.indices.filter { melds[step.to].tiles[$0] == step.tile }
    let target = slots[step.to][positions[min(earlier, positions.count - 1)]]
    return [
      .caption("Step \(index + 1) of \(steps.count)"),
      .source(source),
      .target(target, step.tile),
      .arrow(from: CGPoint(x: source.midX, y: source.midY), to: CGPoint(x: target.midX, y: target.midY)),
    ]
  }
}
