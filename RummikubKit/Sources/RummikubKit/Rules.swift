extension World {
  /// How a scan reads the rack it knew.
  public enum RackScan: Sendable {
    /// As it was: only the tiles it had.
    case known
    /// Afresh, as when it was read wrong: the tiles in no valid meld, whatever Values' rack odds, which large tiles in
    /// a new light kept under .6 (2026-11-13), the most seen up to the rack's size, the same or one more.
    case again
    /// With one tile drawn: every tile it had, seen or hidden behind another, and the new tile seen most.
    case drawing
  }

  /// The table and rack as the world has them, given `before`, the last known state, empty when nothing is: the
  /// table's valid melds, and the rack. With nothing known, 14 tiles in all are a new game's dealt rack, wherever they
  /// lie. With the rack known, a tile in no valid meld is the rack's when the rack had it: seen from above the table,
  /// Values gave rack tiles .32–.56 and the table's up to .30 (2026-11-13), so its odds can't say. How the rack takes
  /// what's left is `scan`'s.
  public func parts(from pose: Pose, knowing before: Scene, scan: RackScan = .known) -> Scene {
    let dealt = before.table.isEmpty && before.rack.isEmpty && places.count(where: \.sure) == 14
    let placed = detections(from: pose, allRack: dealt)
    if dealt { return Scene(table: [], rack: placed.map(\.detection)) }
    let melds = Recognizer.valid(World.melds(placed.filter { !$0.place.isRack })).filter { isMeld($0.map(\.tile)) }
    guard !before.rack.isEmpty else { return Scene(table: melds, rack: placed.filter(\.place.isRack).map(\.detection)) }
    let melded = melds.joined().map(\.frame)
    let loose = placed.indices.filter { !melded.contains(placed[$0].detection.frame) }
    if scan == .again {
      // The tiles seen most, as many as it had, and one more seen about as often: a 21-tile rack read 24, its extras
      // second reads of tiles already there (2026-11-13).
      let seen = loose.sorted { placed[$0].place.seen > placed[$1].place.seen }
      var kept = Array(seen.prefix(before.rack.count))
      if seen.count > kept.count, let last = kept.last,
        placed[seen[kept.count]].place.seen * 2 >= placed[last].place.seen
      {
        kept.append(seen[kept.count])
      }
      return Scene(table: melds, rack: loose.filter(kept.contains).map { placed[$0].detection })
    }
    let kept = Set(Scene.among(loose.sorted { (placed[$0].place.onRack ?? 0) > (placed[$1].place.onRack ?? 0) },
      tile: { placed[$0].detection.tile }, before.rackTiles))
    var rack = loose.filter(kept.contains).map { placed[$0].detection }
    if scan == .drawing {
      // Unseen this time, so placed nowhere: where they were is in a world since forgotten.
      rack += Scene.among(before.rack, tile: \.tile, Scene.missing(before.rackTiles, from: rack.map(\.tile))).map {
        Detection(tile: $0.tile, frame: .null, turns: $0.turns, odds: $0.odds)
      }
      if let new = loose.filter({ !kept.contains($0) }).max(by: { placed[$0].place.seen < placed[$1].place.seen }) {
        rack.append(placed[new].detection)
      }
    }
    return Scene(table: melds, rack: rack)
  }
}

/// What the game allows a scan to say, so what vision gets wrong doesn't become the state: phantom tiles, misreads,
/// and rack tiles taken for the table's.
extension Scene {
  /// Only its valid melds: between turns the table holds nothing else.
  public var melded: Scene { Scene(table: table.filter { isMeld($0.map(\.tile)) }, rack: rack) }

  /// Whether its table can follow `before`'s: other players only add to it, so it keeps every tile it had.
  public func tableFollows(_ before: Scene) -> Bool {
    Self.missing(before.tableTiles.joined(), from: tableTiles.joined()).isEmpty
  }

  /// Whether its rack can follow `before`'s, unknown when empty: as it was, or with one tile drawn. Read again, any
  /// tiles, as many or one more; drawing, exactly one more.
  public func rackFollows(_ before: Scene, scan: World.RackScan = .known) -> Bool {
    guard !before.rack.isEmpty else { return true }
    let more = rack.count - before.rack.count, kept = Self.missing(before.rackTiles, from: rackTiles).isEmpty
    return switch scan {
    case .known: kept && more <= 1
    case .again: more == 0 || more == 1
    case .drawing: kept && more == 1
    }
  }

  /// Whether no tile shows more than twice, table and rack together, as a set holds two of each.
  public var possible: Bool {
    Dictionary(tableTiles.joined().map { ($0, 1) } + rackTiles.map { ($0, 1) }, uniquingKeysWith: +).values.allSatisfy { $0 <= 2 }
  }

  /// Those of `items` whose tile is among `others`, in order, each tile as often as `others` has it.
  public static func among<T>(_ items: [T], tile: (T) -> Tile, _ others: some Sequence<Tile>) -> [T] {
    var left = Dictionary(others.map { ($0, 1) }, uniquingKeysWith: +)
    return items.filter { item in
      guard let n = left[tile(item)], n > 0 else { return false }
      left[tile(item)] = n - 1
      return true
    }
  }

  /// Which of `tiles` aren't among `others`, each counted as often as it shows.
  public static func missing(_ tiles: some Sequence<Tile>, from others: some Sequence<Tile>) -> [Tile] {
    var left = Dictionary(others.map { ($0, 1) }, uniquingKeysWith: +)
    return tiles.filter { tile in
      guard let n = left[tile], n > 0 else { return true }
      left[tile] = n - 1
      return false
    }
  }
}
