/// Every distinct valid meld, as tile counts plus one way to lay it out. Runs stop at five: any longer one splits into
/// these, which keeps the program small, and `plan` joins them back up.
struct Template: Sendable {
  let counts: Counts
  let tiles: [Tile]

  static let all: [Template] = {
    var seen = Set<Counts>()
    var all = [Template]()
    func add(_ tiles: [Tile]) {
      let counts = Counts(tiles)
      if seen.insert(counts).inserted { all.append(Template(counts: counts, tiles: tiles)) }
    }
    for color in TileColor.allCases {
      for start in 1...11 {
        for end in (start + 2)...min(start + 4, 13) {
          let run = (start...end).map { Tile.number(color, $0) }
          for i in run.indices {
            for j in i..<run.count {
              var tiles = run
              tiles[i] = .joker
              tiles[j] = .joker
              add(tiles)
            }
          }
          add(run)
        }
      }
    }
    for value in 1...13 {
      for mask in 1..<16 {
        let tiles = TileColor.allCases.filter { mask & 1 << $0.rawValue != 0 }.map { Tile.number($0, value) }
        for jokers in 0...2 where (3...4).contains(tiles.count + jokers) {
          add(tiles + Array(repeating: .joker, count: jokers))
        }
      }
    }
    return all
  }()
}

/// Whether `tiles` form a group or a run, in any order.
public func isMeld(_ tiles: [Tile]) -> Bool {
  let real = tiles.filter { $0 != .joker }
  guard tiles.count >= 3, let first = real.first else { return false }
  if real.allSatisfy({ $0.value == first.value }) {
    return tiles.count <= 4 && Set(real.map(\.color)).count == real.count
  }
  let values = real.compactMap(\.value)
  return real.allSatisfy { $0.color == first.color } && Set(values).count == values.count
    && values.max()! - values.min()! < tiles.count && tiles.count <= 13
}

