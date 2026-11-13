import CoreGraphics

/// What the camera has seen: the table's melds in the order `solve` gets them, and the rack.
public struct Scene: Sendable {
  public var table: [[Detection]]
  public var rack: [Detection]

  public init(table: [[Detection]], rack: [Detection]) {
    self.table = table
    self.rack = rack
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
  /// melds with no anchor in open table nearest the rest, inside `bounds` (the photo) when given, else in a new row
  /// under the table, which may be off screen. A slot that would cover another meld's tile is lifted above the row,
  /// since there's no room until that meld moves over.
  public func slots(in scene: Scene, within bounds: CGRect? = nil) -> [[CGRect]] {
    let all = scene.table.joined().map(\.frame)
    let size = all.first?.size ?? scene.rack.first?.frame.size ?? CGSize(width: 60, height: 84)
    let pitch = size.width + 2
    var free = CGPoint(x: all.map(\.minX).min() ?? 0, y: (all.map(\.maxY).max() ?? 0) + size.height / 3)
    var taken = all
    let center = all.isEmpty ? nil : CGPoint(x: all.map(\.midX).reduce(0, +) / CGFloat(all.count),
      y: all.map(\.midY).reduce(0, +) / CGFloat(all.count))
    /// The open spot for a row of `count` tiles nearest the table's middle, a third of a tile clear of every tile.
    func open(_ count: Int) -> CGPoint? {
      guard let bounds else { return nil }
      let width = CGFloat(count) * pitch, gap = size.height / 3
      let middle = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
      return stride(from: bounds.minX + gap, through: bounds.maxX - width - gap, by: pitch / 2).flatMap { x in
        stride(from: bounds.minY + gap, through: bounds.maxY - size.height - gap, by: size.height / 2).map {
          CGPoint(x: x, y: $0)
        }
      }
      .filter { point in
        let row = CGRect(origin: point, size: CGSize(width: width, height: size.height)).insetBy(dx: -gap, dy: -gap)
        return !taken.contains { $0.intersects(row) }
      }
      .min { a, b in
        hypot(a.x + width / 2 - middle.x, a.y + size.height / 2 - middle.y)
          < hypot(b.x + width / 2 - middle.x, b.y + size.height / 2 - middle.y)
      }
    }
    let anchored = melds.map { meld -> [CGRect]? in
      guard let anchor = meld.anchor else { return nil }
      let tiles = meld.tiles, old = scene.table[anchor]
      let pairs = tiles.indices.compactMap { i in old.firstIndex { $0.tile == tiles[i] }.map { (i, old[$0].frame) } }
      guard let (i, frame) = pairs.first else { return nil }
      let others = scene.table.indices.filter { $0 != anchor }.flatMap { scene.table[$0].map(\.frame) }
      return tiles.indices.map {
        let slot = frame.offsetBy(dx: CGFloat($0 - i) * pitch, dy: 0)
        let covers = others.contains { $0.intersects(slot.insetBy(dx: size.width / 10, dy: size.height / 10)) }
        return covers ? slot.offsetBy(dx: 0, dy: -size.height * 1.1) : slot
      }
    }
    taken += anchored.compactMap(\.self).joined()
    return melds.indices.map { n in
      if let slots = anchored[n] { return slots }
      let tiles = melds[n].tiles
      let origin: CGPoint
      if let spot = open(tiles.count) {
        origin = spot
      } else {
        origin = free
        free.x += CGFloat(tiles.count) * pitch + size.width / 2
      }
      let row = tiles.indices.map { CGRect(origin: CGPoint(x: origin.x + CGFloat($0) * pitch, y: origin.y), size: size) }
      taken += row
      return row
    }
  }

  /// The scene once every step is done: the new melds in their slots, and the rack without what went to the table.
  public func finished(_ scene: Scene, within bounds: CGRect? = nil) -> Scene {
    let table = zip(melds, slots(in: scene, within: bounds)).map { meld, slots in
      zip(meld.tiles, slots).map { Detection(tile: $0, frame: $1) }
    }
    let used = Set(steps.compactMap { if case .rack(let i) = $0.from { i } else { nil } })
    return Scene(table: table, rack: scene.rack.indices.filter { !used.contains($0) }.map { scene.rack[$0] })
  }

  /// How many steps the table, read as `table`, shows done. A step is done once some meld read there holds its tile
  /// and everything already placed in its destination, and nothing that belongs in neither it nor the old meld it
  /// stays in place of, whose leaving tiles may not have left yet.
  public func stepsDone(_ table: [[Tile]], from old: [[Tile]]) -> Int {
    let read = table.map(Counts.init)
    let anchors = melds.map { $0.anchor.map { Counts(old[$0]) } ?? Counts() }
    var placed = melds.indices.map { pointwiseMin(anchors[$0], Counts(melds[$0].tiles)) }
    for (index, step) in steps.enumerated() {
      let destination = Counts(melds[step.to].tiles)
      let allowed = pointwiseMax(destination, anchors[step.to])
      var expected = placed[step.to]
      expected[step.tile.index] += 1
      guard read.contains(where: { all($0 .<= allowed) && all(expected .<= $0) }) else { return index }
      placed[step.to] = expected
    }
    return steps.count
  }

  /// The steps from `index` on that take tiles from the same place, the rack or one meld, to the same meld: shown and
  /// done as one, like three 6s from the rack laid down as a group.
  public func group(at index: Int) -> Range<Int> {
    func same(_ a: Source, _ b: Source) -> Bool {
      switch (a, b) {
      case (.rack, .rack): true
      case (.table(let m, _), .table(let n, _)): m == n
      default: false
      }
    }
    var end = index + 1
    while end < steps.count, steps[end].to == steps[index].to, same(steps[end].from, steps[index].from) { end += 1 }
    return index..<end
  }

  /// Where each group of steps starts.
  public var groups: [Int] {
    sequence(first: 0) { group(at: $0).upperBound }.prefix { $0 < steps.count }.map(\.self)
  }

  /// What to draw for step `index`: the tile to pick up, where it goes, and an arrow between.
  public func marks(in scene: Scene, step index: Int, within bounds: CGRect? = nil) -> [Mark] {
    let step = steps[index]
    let source: CGRect =
      switch step.from {
      case .rack(let i): scene.rack[i].frame
      case .table(let meld, let i): scene.table[meld][i].frame
      }
    let slots = slots(in: scene, within: bounds)
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
