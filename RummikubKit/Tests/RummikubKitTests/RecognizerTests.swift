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
  let image = Render.table(table, width: Int(size.width), height: Int(size.height))
  save(image, "table\(Int(size.width))")
  let read = Recognizer.melds(Recognizer.tiles(in: image)).map { $0.map(\.tile) }
  #expect(read == table)
}

#if os(macOS)
  /// Renders the reference glyphs and checks them against `References.bin`, or with `BAKE=1` writes it. They're baked
  /// on macOS because iOS renders the fonts differently, and needs a change here whenever recognition's thresholds do.
  @Test func bakesReferences() throws {
    let tiles = (1...13).map { Tile.number(.black, $0) } + [.joker]
    var references = [(label: Int, glyph: Glyph)]()
    for font in ["Helvetica-Bold", "Arial-BoldMT", "Futura-Bold", "AvenirNext-Heavy", "Verdana-Bold"] {
      let pixels = Pixels(Render.table([tiles], height: 300, font: font))
      for (tile, numeral) in zip(tiles, pixels.numerals().sorted { $0.box.minX < $1.box.minX }) {
        references.append((tile.value ?? 0, pixels.glyph(in: numeral.box)!))
        for (digit, part) in zip(String(tile.value ?? 0), numeral.digits) where tile.value != nil {
          references.append((100 + Int(String(digit))!, pixels.glyph(in: part)!))
        }
      }
    }
    if ProcessInfo.processInfo.environment["BAKE"] != nil {
      var data = Data()
      for (label, glyph) in references {
        data.append(UInt8(label))
        glyph.cells.withUnsafeBytes { data.append(contentsOf: $0) }
      }
      try data.write(to: 
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/RummikubKit/References.bin"))
    } else {
      #expect(references.map(\.label) == Recognizer.references.map(\.label))
      #expect(zip(references, Recognizer.references).allSatisfy { zip($0.glyph.cells, $1.glyph.cells).allSatisfy { abs($0 - $1) < 1e-6 } })
    }
  }
#endif

/// Captures from the phone, each with what it was looking at and its true melds in `<name>.txt`. Prints each one's
/// misreads, and fails only if there are more in all than the last count. `CAPTURES=<dir>` scores that directory
/// instead, without failing.
@Test func readsCaptures() throws {
  let captures = ProcessInfo.processInfo.environment["CAPTURES"].map { URL(filePath: $0) }
  let fixtures = try captures ?? #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  var wrong = 0
  for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).sorted(by: {
    $0.path < $1.path
  }) where url.pathExtension == "png" {
    let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil))
    let lines = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
      .split(separator: "\n")
    let truth = Counts(Tile.parse(lines.dropFirst().joined(separator: " ")))
    let read = Counts(Recognizer.tiles(in: image).map(\.tile))
    let missed = tiles(truth &- pointwiseMin(truth, read)), extra = tiles(read &- pointwiseMin(truth, read))
    wrong += missed.count + extra.count
    print(url.deletingPathExtension().lastPathComponent, "missed", missed.count, missed, "extra", extra.count, extra)
  }
  print("wrong", wrong)
  if captures == nil { #expect(wrong <= 65) }
}

func tiles(_ counts: Counts) -> [Tile] {
  (0...52).flatMap { i in
    repeatElement(i == 52 ? Tile.joker : .number(TileColor(rawValue: i % 4)!, i / 4 + 1), count: Int(counts[i]))
  }
}

@Test func liftsSlotsThatCoverAnotherMeld() throws {
  let table = melds("k1 k2 k3, b9 b10 b11")
  let image = Render.table(table)
  let scene = Scene(table: Recognizer.melds(Recognizer.tiles(in: image)), rack: [])
  let play = try #require(solve(table: scene.tableTiles, rack: Tile.parse("k4")).last)
  let k4 = play.slots(in: scene)[0][3]
  #expect(k4.minY < scene.table[0][0].frame.minY)
  #expect(!scene.table[1].contains { $0.frame.intersects(k4) })
}

@Test func putsNewMeldsInOpenTableOnScreen() throws {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12")
  let image = Render.table(table, rack: Tile.parse("o7 o8 o9"))
  let scene = Scene(Recognizer.tiles(in: image), rackY: CGFloat(image.height) - 150)
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

@Test func followsTheCamera() {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12")
  let before = Scene(table: Recognizer.melds(Recognizer.tiles(in: Render.table(table))), rack: [])
  let after = Recognizer.tiles(in: Render.table(table, top: 130))
  let moved = before.following(after).table.joined().map(\.frame)
  let expected = Recognizer.melds(after).joined().map(\.frame)
  #expect(zip(moved, expected).allSatisfy { abs($0.midX - $1.midX) < 2 && abs($0.midY - $1.midY) < 2 })
}

@Test func walksThroughSteps() throws {
  let table = melds("r3 r4 r5 r6, k1 k2 k3, b9 b10 b11, o12 r12 b12")
  let rack = Tile.parse("b6 k6 k4 o5 b13 o9 j")
  let image = Render.table(table, rack: rack)
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
