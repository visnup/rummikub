// Replays AR frames through `World`: a recording's log (`<start>.jsonl`, a frame a line) or a capture's `ar.history`.
// Prints each frame's reads and places, then the table and rack it ends with, as melds seen from the last frame.
//   swift run world ../Captures/<start>.jsonl ../Captures/unlabeled/<time>.json ...
import Foundation
import RummikubKit
import simd

for path in CommandLine.arguments.dropFirst() {
  let history = try Recording(contentsOf: URL(filePath: path)).frames
  guard let first = history.first else { continue }
  print(URL(filePath: path).lastPathComponent)
  var world = World(), last: Pose?, previous = first.time, before = Scene()
  for frame in history {
    // The camera restarted, and the app with it forgets every place, but knows what it showed.
    if frame.time - previous > 2, frame.tracking != "normal" {
      world = World()
      before = frame.shown ?? before
      print("  restarted, knowing \(before.rack.count) on the rack and \(before.table.joined().count) on the table")
    }
    previous = frame.time
    let ids = frame.tracking == "normal" ? world.add(frame.detections, pose: frame.pose, mask: frame.mask) : []
    if frame.pose.plane != nil { last = frame.pose }
    let covered = frame.mask.map { m in String(format: "  person %2.0f%%", 100 * Double(m.bytes.count { $0 > 0 }) / Double(m.bytes.count)) } ?? ""
    print(String(format: "  %5.1f s  %-5@ %2d read, %2d placed, %2d places, %2d sure%@",
      frame.time - first.time, frame.looking, frame.detections.count,
      ids.count { $0 != nil }, world.places.count, world.places.count(where: \.sure), covered))
  }
  guard let last else { continue }
  let seen = world.detections(from: last)
  let rack = seen.filter(\.place.isRack).map(\.detection), table = seen.filter { !$0.place.isRack }
  func line(_ ds: [Detection]) -> String { ds.map(\.tile.description).joined(separator: " ") }
  print("  rack:  " + line(Recognizer.melds(rack).flatMap(\.self)))
  // The rack as the Board lays it out, a slot a tile wide.
  let laid = Scene.laid(rack), unit: CGFloat = (laid.map(\.frame.height).max() ?? 1) * 0.78
  for row in Dictionary(grouping: laid, by: \.frame.minY).sorted(by: { $0.key < $1.key }).map(\.value) {
    var line = "         "
    for d in row.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      let column: Int = 9 + Int((d.frame.minX / unit * 4).rounded())
      line += String(repeating: " ", count: max(0, column - line.count))
      line += d.tile.description.padding(toLength: 4, withPad: " ", startingAt: 0)
    }
    print(line)
  }
  print("  table: " + Recognizer.valid(World.melds(table)).map(line).joined(separator: ", "))
  // What the app takes from that, by the game's rules (`World.parts`).
  let parts = world.parts(from: last, knowing: before)
  print("  parts: table " + parts.table.map(line).joined(separator: ", ") + " | rack " + line(parts.rack))
  for (place, _) in seen.sorted(by: { $0.place.seen > $1.place.seen }) {
    let reads = place.reads.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key.description, $0.value) }
      .joined(separator: " ")
    let nearest = world.places.filter { $0.id != place.id }.map { distance($0.point, place.point) }.min() ?? 0
    // Height over width as the tile reads, upright.
    let turned = place.turns.indices.max { place.turns[$0] < place.turns[$1] }! % 2 == 1
    let upright = turned ? 1 / place.aspect : place.aspect
    print(String(format: "    #%-3d seen %2d  rack %.2f  tall %.2f  width %2.0f mm, %2.0f mm from the next, %2.0f mm up  %@",
      place.id, place.seen, place.onRack ?? -1, upright, place.width * 1000, nearest * 1000, place.height * 1000,
      String(reads.prefix(30))))
  }
}
