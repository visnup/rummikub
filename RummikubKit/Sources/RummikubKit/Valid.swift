import Foundation

extension Recognizer {
  /// Each patch of touching tiles read at the one turn they agree on, since a meld's tiles all lie the same way: most
  /// tiles show which way is up, and that settles a lone 6 or 9, which look alike turned half around. Touching in any
  /// direction, since a meld seen sideways runs down the photo, and `melds` only joins tiles side by side.
  public static func turned(_ detections: [Detection]) -> [Detection] {
    var patch = Array(detections.indices)
    func root(_ i: Int) -> Int { patch[i] == i ? i : root(patch[i]) }
    for i in detections.indices {
      for j in detections.indices where j > i {
        let a = detections[i].frame, b = detections[j].frame
        let gap = min(a.width, a.height, b.width, b.height) * 0.3
        if a.insetBy(dx: -gap, dy: -gap).intersects(b) { patch[root(j)] = root(i) }
      }
    }
    var turned = detections
    for members in Dictionary(grouping: detections.indices, by: root).values {
      for (i, d) in zip(members, Self.oneTurn(members.map { detections[$0] })) { turned[i] = d }
    }
    return turned
  }

  /// Tiles read upright, as on a rack.
  public static func upright(_ detections: [Detection]) -> [Detection] { oneTurn(detections, at: 0) }

  /// One patch at its likeliest turn, or at `turn`.
  static func oneTurn(_ patch: [Detection], at turn: Int? = nil) -> [Detection] {
    guard turn != nil || patch.count >= 2, patch.allSatisfy({ !$0.turned.isEmpty }) else { return patch }
    func fit(_ k: Int) -> Float { patch.reduce(0) { $0 + log(max($1.turned.values.reduce(0) { $0 + $1[k] }, 1e-4)) } }
    let turn = turn ?? (0..<4).max { fit($0) < fit($1) }!
    return patch.map { d in
      let odds = d.turned.mapValues { $0[turn] }
      let total = odds.values.reduce(0, +)
      guard total > 0, let best = odds.max(by: { $0.value < $1.value }) else { return d }
      return Detection(
        tile: best.key, frame: d.frame, turns: turn, odds: odds.mapValues { $0 / total }.filter { $0.value >= 0.001 },
        turned: d.turned)
    }
  }

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
