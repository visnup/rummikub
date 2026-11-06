import Testing

@testable import RummikubKit

func melds(_ string: String) -> [[Tile]] {
  string.split(separator: ",").map { Tile.parse(String($0)) }
}

/// The plays as (placed, moved), after checking each one is a legal table.
func options(_ table: String, _ rack: String) -> [[Int]] {
  let table = melds(table)
  let rack = Tile.parse(rack)
  let plays = solve(table: table, rack: rack)
  for play in plays {
    #expect(play.melds.allSatisfy { isMeld($0.tiles) }, "\(play.melds)")
    let placed = play.steps.compactMap { if case .rack(let i) = $0.from { rack[i] } else { nil } }
    #expect(Counts(play.melds.flatMap(\.tiles)) == Counts(table.joined()) &+ Counts(placed))
  }
  return plays.map { [$0.placed, $0.moved] }
}

@Test func meldTemplates() {
  #expect(isMeld(Tile.parse("r5 r6 r7")))
  #expect(isMeld(Tile.parse("r7 r5 j")))
  #expect(isMeld(Tile.parse("r5 b5 k5 o5")))
  #expect(isMeld(Tile.parse("j j r13")))
  #expect(!isMeld(Tile.parse("r5 r6")))
  #expect(!isMeld(Tile.parse("r5 b5 k5 o5 j")))
  #expect(!isMeld(Tile.parse("r12 r13 r1")))
  #expect(!isMeld(Tile.parse("r5 r5 b5")))
}

@Test func extendRun() {
  #expect(options("r5 r6 r7", "r8 k1") == [[1, 0]])
}

@Test func nothingToPlay() {
  #expect(options("r5 r6 r7", "k1 b9") == [[0, 0]])
}

@Test func takeFromRun() {
  #expect(options("r3 r4 r5 r6", "b6 k6") == [[0, 0], [2, 1]])
}

@Test func tradeoff() {
  #expect(options("r4 r5 r6 r7, b4 b5 b6 b7", "k4 o4 k10 k11 k12") == [[3, 0], [5, 1]])
}

@Test func rackOnly() {
  #expect(options("", "j r1 r2 b9") == [[3, 0]])
}

@Test func freeJoker() {
  #expect(options("r5 j r7", "r6 b8 k8") == [[1, 0], [3, 1]])
}

@Test func invalidTable() {
  #expect(options("r5 r6", "k1") == [])
  #expect(options("r5 r6", "r7") == [[1, 0]])
}

@Test func stepsKeepAnchors() {
  let plays = solve(table: melds("r3 r4 r5 r6, k1 k2 k3"), rack: Tile.parse("b6 k6"))
  let play = plays.last!
  #expect(play.melds.map(\.anchor) == [0, 1, nil])
  #expect(play.steps.map(\.from) == [.table(meld: 0, index: 3), .rack(1), .rack(0)])
  #expect(play.steps.allSatisfy { $0.to == 2 })
}

@Test func midgame() {
  let table = """
    r1 r2 r3 r4, b5 b6 b7, k9 k10 k11 k12 k13, o2 o3 o4, r9 b9 o9, k7 b7 o7 r7, \
    r10 r11 r12, b11 b12 b13, o5 o6 o7 o8, k1 b1 o1, j k4 k5, r13 b13 k13 o13
    """
  let rack = "r5 r6 b2 b3 k6 o10 o11 r8 k2 b10 j o12 k8 b4"
  #expect(options(table, rack) == [[14, 0]])
  #expect(options(table, rack.replacing(" j", with: "")) == [[12, 0], [13, 4]])
}
