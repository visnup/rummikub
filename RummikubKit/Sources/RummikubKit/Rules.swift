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
