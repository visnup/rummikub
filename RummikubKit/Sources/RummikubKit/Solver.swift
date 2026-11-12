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
/// A player who hasn't `opened` may only lay melds of their own worth 30 or more, and not touch the table.
public func solve(table: [[Tile]], rack: [Tile], opened: Bool = true) -> [Play] {
  guard opened else {
    let kept = table.indices.map { Play.Meld(tiles: table[$0], anchor: $0) }
    let nothing = Play(melds: kept, steps: [])
    guard let melds = opening(rack) else { return [nothing] }
    let laid = plan(table: [], rack: rack, melds: melds)
    let steps = laid.steps.map { Play.Step(tile: $0.tile, from: $0.from, to: $0.to + table.count) }
    return [nothing, Play(melds: kept + laid.melds, steps: steps)]
  }
  let plays = front(table: table, rack: rack)
    .map { plan(table: table, rack: rack, melds: $0) }
    .sorted { ($0.placed, -$0.moved) > ($1.placed, -$1.moved) }
  var fewest = Int.max
  return plays.filter {
    defer { fewest = min(fewest, $0.moved) }
    return $0.moved < fewest
  }.reversed()
}

/// The final melds at each point of the Pareto front of tiles placed against tiles kept, from the integer program of
/// Den Hertog and Hulshof (2006): how many of each candidate meld to lay out, using every table tile and any rack
/// tiles. Candidates are `Template.all`, plus ways to keep most of each old meld, which count its tiles as kept.
/// "Kept" steers toward few moves; `plan` counts the real ones.
func front(table: [[Tile]], rack: [Tile]) -> [[[Tile]]] {
  let onTable = Counts(table.joined())
  let inRack = Counts(rack)
  let available = onTable &+ inRack
  var candidates = [(tiles: [Tile], counts: Counts, most: Int, old: Int?, kept: Int)]()
  for template in Template.all where !any(template.counts .> available) {
    candidates.append((template.tiles, template.counts, any(template.counts &* 2 .> available) ? 1 : 2, nil, 0))
  }
  for (k, meld) in table.enumerated() {
    let old = Counts(meld)
    for tiles in keeps(meld, available: available) {
      let counts = Counts(tiles)
      candidates.append((tiles, counts, 1, k, old.overlap(counts)))
    }
  }
  let types = (0..<53).filter { available[$0] > 0 }
  let held = types.filter { inRack[$0] > 0 }
  let olds = Array(Set(candidates.compactMap(\.old))).sorted()
  // Columns: tiles placed, tiles kept, candidates, rack tiles used, and slack for each old meld's "keep one" row.
  // Rows: each tile, each old meld, then the sums for placed and kept.
  let first = 2
  let rows = types.count + olds.count + 2
  let columns = first + candidates.count + held.count + olds.count
  let placedRow = rows - 2, keptRow = rows - 1
  var matrix = [Double](repeating: 0, count: rows * columns)
  var row = [Int](repeating: 0, count: 53)
  for (i, t) in types.enumerated() { row[t] = i }
  matrix[placedRow * columns] = -1
  matrix[keptRow * columns + 1] = -1
  for (c, candidate) in candidates.enumerated() {
    for t in types where candidate.counts[t] > 0 { matrix[row[t] * columns + first + c] = Double(candidate.counts[t]) }
    if let old = candidate.old {
      matrix[(types.count + olds.firstIndex(of: old)!) * columns + first + c] = 1
      matrix[keptRow * columns + first + c] = Double(candidate.kept)
    }
  }
  for (h, t) in held.enumerated() {
    matrix[row[t] * columns + first + candidates.count + h] = -1
    matrix[placedRow * columns + first + candidates.count + h] = 1
  }
  for o in olds.indices { matrix[(types.count + o) * columns + first + candidates.count + held.count + o] = 1 }
  let tiles = Double(onTable.total)
  var lp = LP(
    matrix: matrix,
    b: types.map { Double(onTable[$0]) } + olds.map { _ in 1 } + [0, 0],
    cost: [-(tiles + 1), -1] + Array(repeating: 0, count: columns - first),
    lower: Array(repeating: 0, count: columns),
    upper: [Double(inRack.total), tiles] + candidates.map { Double($0.most) } + held.map { Double(inRack[$0]) }
      + olds.map { _ in 1 }
  )
  // Each point places the most it can while keeping more than the last.
  var front = [[[Tile]]]()
  while let x = lp.minimize(integers: first + candidates.count, leading: first) {
    front.append(candidates.indices.flatMap { repeatElement(candidates[$0].tiles, count: Int(x[first + $0].rounded())) })
    let kept = x[1].rounded() + 1
    guard kept <= tiles else { break }
    lp.bound(1, kept, tiles)
  }
  return front
}

/// The opening that places the most of `rack`: melds from it alone worth 30 or more, or nil if there's none.
func opening(_ rack: [Tile]) -> [[Tile]]? {
  let inRack = Counts(rack)
  let candidates = Template.all.filter { !any($0.counts .> inRack) }.map { template in
    let (points, tiles) = worth(template.tiles)
    return (tiles: tiles, counts: template.counts, points: points, most: any(template.counts &* 2 .> inRack) ? 1 : 2)
  }
  let held = (0..<53).filter { inRack[$0] > 0 }
  // Columns: candidates, unused rack tiles, points. Rows: each tile in the rack, then the points.
  let columns = candidates.count + held.count + 1
  var matrix = [Double](repeating: 0, count: (held.count + 1) * columns)
  for (r, t) in held.enumerated() {
    for (c, candidate) in candidates.enumerated() { matrix[r * columns + c] = Double(candidate.counts[t]) }
    matrix[r * columns + candidates.count + r] = 1
  }
  let pointsRow = held.count * columns
  for (c, candidate) in candidates.enumerated() { matrix[pointsRow + c] = Double(candidate.points) }
  matrix[pointsRow + columns - 1] = -1
  var lp = LP(
    matrix: matrix,
    b: held.map { Double(inRack[$0]) } + [0],
    cost: candidates.map { -Double($0.counts.total) } + Array(repeating: 0, count: held.count + 1),
    lower: Array(repeating: 0, count: columns - 1) + [30],
    upper: candidates.map { Double($0.most) } + held.map { Double(inRack[$0]) } + [Double(13 * rack.count)]
  )
  guard let x = lp.minimize(integers: candidates.count) else { return nil }
  return candidates.indices.flatMap { repeatElement(candidates[$0].tiles, count: Int(x[$0].rounded())) }
}

/// What a meld counts toward an opening, each joker the tile it stands for, and its tiles laid out that way: a run
/// as high as its tiles allow, or a group, whichever is worth more.
func worth(_ tiles: [Tile]) -> (points: Int, tiles: [Tile]) {
  let real = tiles.filter { $0 != .joker }, values = real.compactMap(\.value), n = tiles.count
  var best = (points: 0, tiles: tiles)
  if Set(values).count == 1, Set(real.map(\.color)).count == real.count, n <= 4 {
    best = (values[0] * n, real + repeatElement(.joker, count: n - real.count))
  }
  if let color = real.first?.color, real.allSatisfy({ $0.color == color }), Set(values).count == values.count,
    values.max()! - values.min()! < n
  {
    let start = min(values.min()!, 14 - n)
    let points = n * start + n * (n - 1) / 2
    if points > best.points {
      best = (points, (start..<start + n).map { values.contains($0) ? .number(color, $0) : .joker })
    }
  }
  return best
}

/// Ways to keep part of the old meld `tiles`: itself, then every run or group that shares at least two of its tiles,
/// with runs reaching up to three values past its own. Jokers stand in for tiles that aren't available, or anywhere
/// the old meld didn't have a real tile.
func keeps(_ tiles: [Tile], available: Counts) -> [[Tile]] {
  guard isMeld(tiles) else { return [] }
  let old = Counts(tiles)
  var seen: Set = [old]
  var keeps = [tiles]
  func add(_ tiles: [Tile]) {
    let counts = Counts(tiles)
    if old.overlap(counts) >= 2 && seen.insert(counts).inserted { keeps.append(tiles) }
  }
  let jokers = min(Int(available[Tile.joker.index]), 2)
  let hasJoker = tiles.contains(.joker)
  for color in TileColor.allCases {
    let values = Set(tiles.compactMap { $0.color == color ? $0.value : nil })
    guard let lo = values.min(), let hi = values.max(), values.count >= 2 || hasJoker else { continue }
    for low in max(1, lo - 3)...min(hi, 11) {
      for high in max(low + 2, lo)...min(13, hi + 3) {
        let free = (low...high).filter { !values.contains($0) }
        let missing = free.filter { available[Tile.number(color, $0).index] == 0 }
        guard missing.count <= jokers else { continue }
        for mask in 0..<(jokers == 0 ? 1 : 1 << free.count) where mask.nonzeroBitCount <= jokers {
          let wild = free.indices.filter { mask & 1 << $0 != 0 }.map { free[$0] }
          guard missing.allSatisfy(wild.contains) else { continue }
          add((low...high).map { wild.contains($0) ? .joker : .number(color, $0) })
        }
      }
    }
  }
  for value in Set(tiles.compactMap(\.value)) {
    for mask in 1..<16 {
      let group = TileColor.allCases.filter { mask & 1 << $0.rawValue != 0 }.map { Tile.number($0, value) }
      guard group.allSatisfy({ available[$0.index] > 0 }) else { continue }
      for wild in 0...jokers where (3...4).contains(group.count + wild) {
        add(group + repeatElement(.joker, count: wild))
      }
    }
  }
  return keeps
}

/// Assigns physical tiles to `melds`. Old and new melds pair up greedily by overlap; a new meld stays where its old
/// one was and keeps its tiles, and takes the rest from elsewhere on the table or from the rack.
func plan(table: [[Tile]], rack: [Tile], melds: [[Tile]]) -> Play {
  let old = table.map(Counts.init)
  var made = melds
  // Rejoin runs the templates split up, unless the pieces stay with different old melds.
  func closest(_ tiles: [Tile]) -> Int? {
    let counts = Counts(tiles)
    return old.indices.filter { old[$0].overlap(counts) > 0 }.max { old[$0].overlap(counts) < old[$1].overlap(counts) }
  }
  func plainRun(_ tiles: [Tile]) -> (color: TileColor, first: Int, last: Int)? {
    guard !tiles.contains(.joker), let color = tiles[0].color, tiles[1].color == color else { return nil }
    return (color, tiles.first!.value!, tiles.last!.value!)
  }
  joining: while true {
    for i in made.indices {
      guard let a = plainRun(made[i]) else { continue }
      for j in made.indices where j != i {
        guard let b = plainRun(made[j]), a.color == b.color, a.last + 1 == b.first else { continue }
        let x = closest(made[i]), y = closest(made[j])
        guard x == nil || y == nil || x == y else { continue }
        made[i] += made[j]
        made.remove(at: j)
        continue joining
      }
    }
    break
  }
  var anchors = [(meld: Int, overlap: Int)?](repeating: nil, count: made.count)
  var anchored = Set<Int>()
  let pairs = made.indices.flatMap { n in old.indices.map { (n, $0, old[$0].overlap(Counts(made[n]))) } }
  for (n, meld, overlap) in pairs.sorted(by: { $0.2 > $1.2 }) where overlap > 0 {
    if anchors[n] == nil && anchored.insert(meld).inserted { anchors[n] = (meld, overlap) }
  }
  let order = made.indices.sorted { (anchors[$0]?.meld ?? .max) < (anchors[$1]?.meld ?? .max) }
  made = order.map { made[$0] }
  anchors = order.map { anchors[$0] }
  var need = made.map(Counts.init)
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
      for _ in 0..<need[n][tile] {
        let i = rackLeft.firstIndex { rack[$0].index == tile }!
        steps.append(Play.Step(tile: rack[rackLeft[i]], from: .rack(rackLeft.remove(at: i)), to: n))
      }
    }
  }
  return Play(
    melds: made.indices.map { Play.Meld(tiles: made[$0], anchor: anchors[$0]?.meld) },
    steps: steps
  )
}
