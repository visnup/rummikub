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

@Test func twoOfEachTile() {
  #expect(scene("r1 r2 r3", "r1").possible)
  #expect(!scene("r1 r2 r3, r1 b1 k1", "r1").possible)
}
