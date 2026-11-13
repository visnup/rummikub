extension World {
  /// The table and rack as the world has them, given `before`, the last known state, empty when nothing is: the
  /// table's valid melds, and the rack. With nothing known, 14 tiles in all are a new game's dealt rack, wherever they
  /// lie. With the rack known, a tile in no valid meld is the rack's when the rack had it: seen from above the table,
  /// Values gave rack tiles .32–.56 and the table's up to .30 (2026-11-13), so its odds can't say. The rack then
  /// keeps only the tiles it had, the most rack-like of each, so a phantom can't join it.
  public func parts(from pose: Pose, knowing before: Scene) -> Scene {
    let dealt = before.table.isEmpty && before.rack.isEmpty && places.count(where: \.sure) == 14
    let placed = detections(from: pose, allRack: dealt)
    if dealt { return Scene(table: [], rack: placed.map(\.detection)) }
    let melds = Recognizer.valid(World.melds(placed.filter { !$0.place.isRack })).filter { isMeld($0.map(\.tile)) }
    guard !before.rack.isEmpty else { return Scene(table: melds, rack: placed.filter(\.place.isRack).map(\.detection)) }
    let melded = melds.joined().map(\.frame)
    let loose = placed.indices.filter { placed[$0].place.isRack || !melded.contains(placed[$0].detection.frame) }
    let kept = Set(Scene.among(loose.sorted { (placed[$0].place.onRack ?? 0) > (placed[$1].place.onRack ?? 0) },
      tile: { placed[$0].detection.tile }, before.rackTiles))
    return Scene(table: melds, rack: loose.filter(kept.contains).map { placed[$0].detection })
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

  /// Whether its rack can follow `before`'s, unknown when empty: as it was, or with one tile drawn.
  public func rackFollows(_ before: Scene) -> Bool {
    before.rack.isEmpty || Self.missing(before.rackTiles, from: rackTiles).isEmpty && rack.count - before.rack.count <= 1
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
