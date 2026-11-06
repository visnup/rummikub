/// One way to play a turn: the table afterward, and the moves that get it there.
public struct Play: Sendable {
  public enum Source: Hashable, Sendable {
    case rack(Int)
    case table(meld: Int, index: Int)
  }

  public struct Step: Hashable, Sendable {
    public let tile: Tile
    public let from: Source
    /// Index into `melds`.
    public let to: Int
  }

  public struct Meld: Hashable, Sendable {
    public let tiles: [Tile]
    /// The meld on the table this one stays in place of, or nil for one laid down somewhere new.
    public let anchor: Int?
  }

  public let melds: [Meld]
  public let steps: [Step]

  public var placed: Int {
    steps.count {
      if case .rack = $0.from { true } else { false }
    }
  }

  public var moved: Int { steps.count - placed }
}

/// The plays worth considering: for each number of tiles placed from the rack, the one that moves the fewest tiles
/// already on the table. Ordered by tiles placed, so the first is always "place nothing" when `table` is valid.
public func solve(table: [[Tile]], rack: [Tile]) -> [Play] {
  let search = Search(old: table)
  let start = Search.Key(table: Counts(table.joined()), rack: Counts(rack))
  let plays = search.front(start)
    .map { plan(table: table, rack: rack, old: search.old, moves: search.path(start, $0)) }
    .sorted { ($0.placed, -$0.moved) > ($1.placed, -$1.moved) }
  var fewest = Int.max
  return plays.filter {
    defer { fewest = min(fewest, $0.moved) }
    return $0.moved < fewest
  }.reversed()
}

struct Move {
  /// Index into `Template.all`, or nil to leave a rack tile in the rack.
  let template: Int?
  let fromTable: Counts
  let fromRack: Counts
}

/// Exhaustive search over ways to cover every table tile and any rack tiles with melds, memoized on what's left.
/// It keeps a Pareto front of tiles placed against tiles kept, where a meld keeps the tiles it shares with an old
/// meld it has most of, or with an old run of the same color (a piece of a long run). It's a heuristic for
/// steering the search: duplicates can overcount, so `plan` counts the real moves.
final class Search {
  struct Key: Hashable {
    let table: Counts
    let rack: Counts

    func after(_ move: Move) -> Key { Key(table: table &- move.fromTable, rack: rack &- move.fromRack) }
  }

  struct Entry: Equatable {
    let placed: Int
    let kept: Int
  }

  /// Templates by their lowest tile, since `moves` only ever settles the lowest tile left.
  static let byTile = (0..<53).map { tile in Template.all.indices.filter { Template.all[$0].counts.first == tile } }

  let old: [Counts]
  var memo = [Key: [Entry]]()

  let oldColors: [TileColor?]

  init(old: [[Tile]]) {
    self.old = old.map(Counts.init)
    oldColors = old.map(runColor)
  }

  /// Every way to settle the lowest tile left: the melds it could go in and, for a rack tile, keeping it. Going in
  /// value order means everything below the lowest tile is settled, so the states left are few, as in a DP by value.
  func moves(_ key: Key) -> [Move] {
    let available = key.table &+ key.rack
    guard let tile = available.first else { return [] }
    var keep = [Move]()
    if key.table[tile] == 0 {
      var counts = Counts()
      counts[tile] = 1
      keep.append(Move(template: nil, fromTable: .zero, fromRack: counts))
    }
    return keep
      + Self.byTile[tile].compactMap {
        let counts = Template.all[$0].counts
        if any(counts .> available) { return nil }
        let fromTable = pointwiseMin(counts, key.table)
        return Move(template: $0, fromTable: fromTable, fromRack: counts &- fromTable)
      }
  }

  func gain(_ move: Move) -> Entry {
    guard let template = move.template else { return Entry(placed: 0, kept: 0) }
    let color = Template.all[template].color
    let kept = old.indices.map {
      let overlap = old[$0].overlap(move.fromTable)
      return 2 * overlap > old[$0].total || (color != nil && color == oldColors[$0]) ? overlap : 0
    }
    return Entry(placed: move.fromRack.total, kept: kept.max() ?? 0)
  }

  func front(_ key: Key) -> [Entry] {
    if key.table == .zero && key.rack == .zero { return [Entry(placed: 0, kept: 0)] }
    if let front = memo[key] { return front }
    var front = [Entry]()
    for move in moves(key) {
      let gain = gain(move)
      for rest in self.front(key.after(move)) {
        let entry = Entry(placed: rest.placed + gain.placed, kept: rest.kept + gain.kept)
        if front.contains(where: { $0.placed >= entry.placed && $0.kept >= entry.kept }) { continue }
        front.removeAll { $0.placed <= entry.placed && $0.kept <= entry.kept }
        front.append(entry)
      }
    }
    memo[key] = front
    return front
  }

  func path(_ key: Key, _ target: Entry) -> [Move] {
    if key.table == .zero && key.rack == .zero { return [] }
    for move in moves(key) {
      let gain = gain(move)
      let rest = Entry(placed: target.placed - gain.placed, kept: target.kept - gain.kept)
      if front(key.after(move)).contains(rest) { return [move] + path(key.after(move), rest) }
    }
    preconditionFailure("\(target) isn't on the front")
  }
}

/// Assigns physical tiles to the melds `moves` makes. Old and new melds pair up greedily by overlap; a new meld stays
/// where its old one was and keeps its tiles, and takes the rest from elsewhere on the table or from the rack.
func plan(table: [[Tile]], rack: [Tile], old: [Counts], moves: [Move]) -> Play {
  struct Made {
    var tiles: [Tile]
    var fromTable: Counts
    var fromRack: Counts
  }
  var made = moves.compactMap { move in
    move.template.map { Made(tiles: Template.all[$0].tiles, fromTable: move.fromTable, fromRack: move.fromRack) }
  }
  // Rejoin runs the search split up, unless the pieces stay with different old melds.
  func closest(_ counts: Counts) -> Int? {
    old.indices.filter { old[$0].overlap(counts) > 0 }.max { old[$0].overlap(counts) < old[$1].overlap(counts) }
  }
  func plainRun(_ tiles: [Tile]) -> (color: TileColor, first: Int, last: Int)? {
    guard !tiles.contains(.joker), let color = tiles[0].color, tiles[1].color == color else { return nil }
    return (color, tiles.first!.value!, tiles.last!.value!)
  }
  joining: while true {
    for i in made.indices {
      guard let a = plainRun(made[i].tiles) else { continue }
      for j in made.indices where j != i {
        guard let b = plainRun(made[j].tiles), a.color == b.color, a.last + 1 == b.first else { continue }
        let x = closest(made[i].fromTable), y = closest(made[j].fromTable)
        guard x == nil || y == nil || x == y else { continue }
        made[i].tiles += made[j].tiles
        made[i].fromTable &+= made[j].fromTable
        made[i].fromRack &+= made[j].fromRack
        made.remove(at: j)
        continue joining
      }
    }
    break
  }
  var anchors = [(meld: Int, overlap: Int)?](repeating: nil, count: made.count)
  var anchored = Set<Int>()
  let pairs = made.indices.flatMap { n in old.indices.map { (n, $0, old[$0].overlap(made[n].fromTable)) } }
  for (n, meld, overlap) in pairs.sorted(by: { $0.2 > $1.2 }) where overlap > 0 {
    if anchors[n] == nil && anchored.insert(meld).inserted { anchors[n] = (meld, overlap) }
  }
  let order = made.indices.sorted { (anchors[$0]?.meld ?? .max) < (anchors[$1]?.meld ?? .max) }
  made = order.map { made[$0] }
  anchors = order.map { anchors[$0] }
  var need = made.map(\.fromTable)
  var claimed = Array(repeating: [Play.Source](), count: made.count)
  let sources = table.indices.flatMap { meld in table[meld].indices.map { (meld, $0) } }
  var unclaimed = Set(sources.map { Play.Source.table(meld: $0.0, index: $0.1) })

  func claim(_ n: Int, _ meld: Int, _ index: Int) {
    let source = Play.Source.table(meld: meld, index: index)
    let tile = table[meld][index].index
    guard unclaimed.contains(source), need[n][tile] > 0 else { return }
    need[n][tile] -= 1
    unclaimed.remove(source)
    claimed[n].append(source)
  }
  for n in made.indices.sorted(by: { (anchors[$0]?.overlap ?? 0) > (anchors[$1]?.overlap ?? 0) }) {
    guard let meld = anchors[n]?.meld else { continue }
    for index in table[meld].indices { claim(n, meld, index) }
  }
  var steps = [Play.Step]()
  var rackLeft = Array(rack.indices)
  for n in made.indices {
    for (meld, index) in sources { claim(n, meld, index) }
    for case .table(let meld, let index) in claimed[n] where meld != anchors[n]?.meld {
      steps.append(Play.Step(tile: table[meld][index], from: .table(meld: meld, index: index), to: n))
    }
    for tile in 0..<53 {
      for _ in 0..<made[n].fromRack[tile] {
        let i = rackLeft.firstIndex { rack[$0].index == tile }!
        steps.append(Play.Step(tile: rack[rackLeft[i]], from: .rack(rackLeft.remove(at: i)), to: n))
      }
    }
  }
  return Play(
    melds: made.indices.map { Play.Meld(tiles: made[$0].tiles, anchor: anchors[$0]?.meld) },
    steps: steps
  )
}
