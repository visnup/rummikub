import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import RummikubKit

/// Writes `image` where `RENDER_DIR` says, for looking at.
func save(_ image: CGImage, _ name: String) {
  guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { return }
  let url = URL(filePath: dir).appending(path: "\(name).png")
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

@Test(arguments: [CGSize(width: 1200, height: 900), CGSize(width: 804, height: 1748)])
func groupsMelds(size: CGSize) {
  let table = melds("r1 r2 r3 r4, b5 b6 b7, j k4 k5, o5 o6 o7 o8, k1 b1 o1, r9 b9 o9, k10 k11 k12 k13, r13 b13 k13 o13")
  let tiles = Render.scene(table, width: Int(size.width), height: Int(size.height)).table.joined().shuffled()
  #expect(Recognizer.melds(tiles).map { $0.map(\.tile) } == table)
}

@Test func liftsSlotsThatCoverAnotherMeld() throws {
  let scene = Render.scene(melds("k1 k2 k3, b9 b10 b11"))
  let play = try #require(solve(table: scene.tableTiles, rack: Tile.parse("k4")).last)
  let k4 = play.slots(in: scene)[0][3]
  #expect(k4.minY < scene.table[0][0].frame.minY)
  #expect(!scene.table[1].contains { $0.frame.intersects(k4) })
}

@Test func putsNewMeldsInOpenTableOnScreen() throws {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12"), rack = Tile.parse("o7 o8 o9")
  let image = Render.table(table, rack: rack)
  let scene = Render.scene(table, rack: rack)
  let play = try #require(solve(table: scene.tableTiles, rack: scene.rackTiles).last)
  // The table, above the rack.
  let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height - 150)
  let new = try #require(play.melds.indices.first { play.melds[$0].anchor == nil })
  let slots = play.slots(in: scene, within: bounds)[new]
  #expect(slots.allSatisfy { bounds.contains($0) })
  #expect(!slots.contains { slot in scene.table.joined().contains { $0.frame.intersects(slot) } })
  for step in play.steps.indices {
    save(Render.overlay(image, play.marks(in: scene, step: step, within: bounds)), "open\(step + 1)")
  }
}

@Test func walksThroughSteps() throws {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12")
  let rack = Tile.parse("b6 k6 k4 o5 b13 o9 j")
  let image = Render.table(table, rack: rack)
  let scene = Render.scene(table, rack: rack)
  let play = try #require(solve(table: scene.tableTiles, rack: scene.rackTiles).last)
  #expect(play.placed == 5)
  for step in play.steps.indices {
    save(Render.overlay(image, play.marks(in: scene, step: step)), "step\(step + 1)")
  }
}
