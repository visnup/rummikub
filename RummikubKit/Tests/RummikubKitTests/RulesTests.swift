import Testing

@testable import RummikubKit

private func scene(_ table: String, _ rack: String = "") -> Scene {
  var scene = Render.scene(melds(table))
  scene.rack = Tile.parse(rack).map { Detection(tile: $0, frame: .zero) }
  return scene
}

@Test func keepsOnlyValidMelds() {
  #expect(scene("r1 r2 r3, o4, o7 r4").melded.tableTiles == melds("r1 r2 r3"))
}

@Test func tableKeepsItsTiles() {
  let before = scene("r1 r2 r3, k5 b5 o5")
  #expect(scene("r1 r2 r3 r4, k5 b5 o5").tableFollows(before))
  #expect(scene("r1 r2, r3 r4 r5, k5 b5 o5").tableFollows(before))
  #expect(!scene("r1 r2 r3").tableFollows(before))
}

@Test func rackGainsAtMostOneTile() {
  let before = scene("", "r1 k2 o3")
  #expect(scene("", "o3 r1 k2").rackFollows(before))
  #expect(scene("", "r1 k2 o3 j").rackFollows(before))
  #expect(!scene("", "r1 k2").rackFollows(before))
  #expect(!scene("", "r1 k2 o3 j b4").rackFollows(before))
  #expect(scene("", "b9").rackFollows(scene("")))
}

@Test func rackReadAgainOrDrawn() {
  let before = scene("", "r1 k2 o3")
  #expect(scene("", "r1 k2 o4").rackFollows(before, scan: .again))
  #expect(!scene("", "r1 k2").rackFollows(before, scan: .again))
  #expect(scene("", "r1 k2 o3 j").rackFollows(before, scan: .drawing))
  #expect(!scene("", "r1 k2 o3").rackFollows(before, scan: .drawing))
}

@Test func laysUnplacedTilesAfterTheRest() {
  var rack = Render.scene([], rack: Tile.parse("r1 r2 r3")).rack
  for i in rack.indices { rack[i].along = Float(i) * 0.027 }
  rack.insert(Detection(tile: Tile("k9")!, frame: .null), at: 1)
  let laid = Scene.laid(rack)
  #expect(laid.map(\.tile) == rack.map(\.tile))
  #expect(laid[1].frame.minX > laid[3].frame.minX && laid[1].frame.minY == laid[3].frame.minY)
}

@Test func twoOfEachTile() {
  #expect(scene("r1 r2 r3", "r1").possible)
  #expect(!scene("r1 r2 r3, r1 b1 k1", "r1").possible)
}
