import Foundation

extension Recognizer {
  /// Each meld that isn't valid read as the likeliest one that is, by the classifier's odds for each tile: a run in
  /// one color either way along the row, or a group of distinct colors, with any tile a joker. Between turns every meld
  /// on the table is valid, so a black 4 5 9 is likelier 4 5 6, our tiles' 6 and 9 differing only in which way is up.
  /// A meld stays as read when nothing valid is within `slack` of it (summed −log odds), since then the meld's
  /// grouping is likelier wrong than its tiles.
  public static func valid(_ melds: [[Detection]], slack: Float = 3) -> [[Detection]] {
    melds.map { meld in
      guard meld.count >= 3, !isMeld(meld.map(\.tile)), meld.allSatisfy({ !$0.odds.isEmpty }) else { return meld }
      func cost(_ detection: Detection, _ tile: Tile) -> Float { -log(max(detection.odds[tile] ?? 0, 1e-4)) }
      var best: (cost: Float, tiles: [Tile])?
      func consider(_ tiles: [Tile]) {
        guard tiles.count(where: { $0 == .joker }) <= 2 else { return }
        let total = zip(meld, tiles).reduce(0) { $0 + cost($1.0, $1.1) }
        if total < best?.cost ?? .infinity { best = (total, tiles) }
      }
      let n = meld.count
      if n <= 13 {
        for color in TileColor.allCases {
          for start in 1...(14 - n) {
            for reversed in [false, true] {
              consider(meld.indices.map { i in
                let tile = Tile.number(color, reversed ? start + n - 1 - i : start + i)
                return cost(meld[i], .joker) < cost(meld[i], tile) ? .joker : tile
              })
            }
          }
        }
      }
      if n <= 4 {
        for value in 1...13 {
          func assign(_ tiles: [Tile], _ used: Set<TileColor>) {
            guard tiles.count < n else { return consider(tiles) }
            assign(tiles + [.joker], used)
            for color in TileColor.allCases where !used.contains(color) {
              assign(tiles + [.number(color, value)], used.union([color]))
            }
          }
          assign([], [])
        }
      }
      let read = meld.reduce(0) { $0 + cost($1, $1.tile) }
      guard let best, best.cost - read <= slack else { return meld }
      return zip(meld, best.tiles).map { Detection(tile: $1, frame: $0.frame, turns: $0.turns, odds: $0.odds) }
    }
  }
}
