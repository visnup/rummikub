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
func readsRenderedTable(size: CGSize) {
  let table = melds("r1 r2 r3 r4, b5 b6 b7, j k4 k5, o5 o6 o7 o8, k1 b1 o1, r9 b9 o9, k10 k11 k12 k13, r13 b13 k13 o13")
  let (image, _) = Render.table(table, width: Int(size.width), height: Int(size.height))
  save(image, "table\(Int(size.width))")
  let read = Recognizer.melds(Recognizer.tiles(in: image)).map { $0.map(\.tile) }
  #expect(read == table)
}

@Test func liftsSlotsThatCoverAnotherMeld() throws {
  let table = melds("k1 k2 k3, b9 b10 b11")
  let (image, _) = Render.table(table)
  let scene = Scene(table: Recognizer.melds(Recognizer.tiles(in: image)), rack: [])
  let play = try #require(solve(table: scene.tableTiles, rack: Tile.parse("k4")).last)
  let k4 = play.slots(in: scene)[0][3]
  #expect(k4.minY < scene.table[0][0].frame.minY)
  #expect(!scene.table[1].contains { $0.frame.intersects(k4) })
}

@Test func walksThroughSteps() throws {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12")
  let rack = Tile.parse("b6 k6 k4 o5 b13 o9 j")
  let (image, _) = Render.table(table, rack: rack)
  let scene = Scene(Recognizer.tiles(in: image), rackY: CGFloat(image.height) - 150)
  #expect(scene.tableTiles == table)
  #expect(scene.rackTiles == rack)
  let play = try #require(solve(table: scene.tableTiles, rack: scene.rackTiles).last)
  #expect(play.placed == 5)
  for step in play.steps.indices {
    let marks = play.marks(in: scene, step: step)
    save(Render.overlay(image, marks), "step\(step + 1)")
  }
}
