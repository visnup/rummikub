import Foundation
import RummikubKit

// Times one solve:
//   swift run -c release bench "r1 r2 r3, b5 b6 b7" "r4 k9"
// or random boards from a shuffled set, up to 16 melds on the table and 14 in the rack, printing the slowest:
//   swift run -c release bench random 800

/// SplitMix64, so a seed gives the same boards on every run.
struct Seeded: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A table of valid melds and a rack, dealt from one set.
func board(_ rng: inout Seeded) -> (table: [[Tile]], rack: [Tile]) {
  var left = [Tile.joker, .joker]
  for color in TileColor.allCases { for value in 1...13 { left += [.number(color, value), .number(color, value)] } }
  func take(_ tile: Tile) -> Bool {
    guard let i = left.firstIndex(of: tile) else { return false }
    left.remove(at: i)
    return true
  }
  var table = [[Tile]]()
  let melds = Int.random(in: 0...16, using: &rng)
  var tries = 0
  while table.count < melds, tries < 1000 {
    tries += 1
    let color = TileColor.allCases.randomElement(using: &rng)!
    var meld: [Tile]
    if Bool.random(using: &rng) {
      let length = Int.random(in: 3...5, using: &rng), start = Int.random(in: 1...(14 - length), using: &rng)
      meld = (start..<start + length).map { .number(color, $0) }
    } else {
      let value = Int.random(in: 1...13, using: &rng)
      meld = TileColor.allCases.shuffled(using: &rng).prefix(Int.random(in: 3...4, using: &rng)).map { .number($0, value) }
    }
    if Int.random(in: 0..<8, using: &rng) == 0 { meld[Int.random(in: meld.indices, using: &rng)] = .joker }
    let before = left
    if meld.allSatisfy(take) { table.append(meld) } else { left = before }
  }
  left.shuffle(using: &rng)
  return (table, Array(left.prefix(Int.random(in: 1...14, using: &rng))))
}

let args = CommandLine.arguments
if args[1] == "random" {
  var rng = Seeded(state: args.count > 3 ? UInt64(args[3])! : 0)
  var times = [(time: Double, table: [[Tile]], rack: [Tile])]()
  for _ in 0..<(Int(args[2]) ?? 800) {
    let (table, rack) = board(&rng)
    let start = Date()
    _ = solve(table: table, rack: rack)
    times.append((Date().timeIntervalSince(start), table, rack))
  }
  let total = times.reduce(0) { $0 + $1.time }
  print(String(format: "%d boards: mean %.1f ms, total %.2f s", times.count, total / Double(times.count) * 1000, total))
  func text(_ tiles: [Tile]) -> String { tiles.map(\.description).joined(separator: " ") }
  for t in times.sorted(by: { $0.time > $1.time }).prefix(5) {
    print(String(format: "%6.0f ms  ", t.time * 1000) + "\"\(t.table.map(text).joined(separator: ", "))\" \"\(text(t.rack))\"")
  }
} else {
  let table = args[1].split(separator: ",").map { Tile.parse(String($0)) }
  let rack = Tile.parse(args[2])
  let start = Date()
  let plays = solve(table: table, rack: rack)
  print(Date().timeIntervalSince(start), plays.map { [$0.placed, $0.moved] })
}
