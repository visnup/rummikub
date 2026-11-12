// Replays AR frames through `World`: a recording's log (`<start>.jsonl`, a frame a line) or a capture's `ar.history`.
// Prints each frame's reads and places, then the table and rack it ends with, as melds seen from the last frame.
//   swift run world ../Captures/<start>.jsonl ../Captures/unlabeled/<time>.json ...
import Foundation
import RummikubKit
import simd

func matrix4(_ v: [Float]) -> simd_float4x4 {
  simd_float4x4(columns: (SIMD4(v[0..<4]), SIMD4(v[4..<8]), SIMD4(v[8..<12]), SIMD4(v[12..<16])))
}

func frames(_ path: String) throws -> [[String: Any]] {
  let data = try Data(contentsOf: URL(filePath: path))
  if path.hasSuffix(".jsonl") {
    return try data.split(separator: UInt8(ascii: "\n")).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
  }
  let notes = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  return (notes["ar"] as? [String: Any])?["history"] as? [[String: Any]] ?? []
}

for path in CommandLine.arguments.dropFirst() {
  let history = try frames(path)
  guard let first = history.first else { continue }
  print(URL(filePath: path).lastPathComponent)
  var world = World(), last: Pose?
  for frame in history {
    let k = (frame["intrinsics"] as! [NSNumber]).map(\.floatValue), size = frame["resolution"] as! [Double]
    let pose = Pose(
      intrinsics: simd_float3x3(columns: (SIMD3(k[0..<3]), SIMD3(k[3..<6]), SIMD3(k[6..<9]))),
      resolution: CGSize(width: size[0], height: size[1]),
      transform: matrix4((frame["transform"] as! [NSNumber]).map(\.floatValue)),
      plane: (frame["plane"] as? [NSNumber]).map { matrix4($0.map(\.floatValue)) })
    let detections = (frame["detections"] as! [[String: Any]]).map { d in
      let f = (d["frame"] as! [Double])
      let odds = (d["odds"] as? [String: NSNumber] ?? [:]).reduce(into: [Tile: Float]()) { $0[Tile($1.key)!] = $1.value.floatValue }
      return Detection(
        tile: Tile(d["tile"] as! String)!, frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]),
        turns: d["turns"] as? Int ?? 0, odds: odds, rack: (d["rack"] as? NSNumber)?.floatValue)
    }
    let mask = (frame["mask"] as? [String: Any]).map {
      World.Mask(width: $0["width"] as! Int, height: $0["height"] as! Int,
        bytes: [UInt8](Data(base64Encoded: $0["bytes"] as! String)!))
    }
    let ids = world.add(detections, pose: pose, mask: mask)
    if pose.plane != nil { last = pose }
    let covered = mask.map { m in String(format: "  person %2.0f%%", 100 * Double(m.bytes.count { $0 > 0 }) / Double(m.bytes.count)) } ?? ""
    print(String(format: "  %5.1f s  %-5@ %2d read, %2d placed, %2d places, %2d sure%@",
      (frame["time"] as! Double) - (first["time"] as! Double), frame["looking"] as? String ?? "", detections.count,
      ids.count { $0 != nil }, world.places.count, world.places.count(where: \.sure), covered))
  }
  guard let last else { continue }
  let seen = world.detections(from: last)
  let rack = seen.filter(\.place.isRack).map(\.detection), table = seen.filter { !$0.place.isRack }.map(\.detection)
  func line(_ ds: [Detection]) -> String { ds.map(\.tile.description).joined(separator: " ") }
  print("  rack:  " + line(Recognizer.melds(rack).joined().map(\.self)))
  print("  table: " + Recognizer.valid(Recognizer.melds(table)).map(line).joined(separator: ", "))
  for (place, _) in seen.sorted(by: { $0.place.seen > $1.place.seen }) {
    let reads = place.reads.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key.description, $0.value) }
      .joined(separator: " ")
    let nearest = world.places.filter { $0.id != place.id }.map { distance($0.point, place.point) }.min() ?? 0
    print(String(format: "    #%-3d seen %2d  rack %.2f  width %2.0f mm, %2.0f mm from the next  %@", place.id, place.seen,
      place.onRack ?? -1, place.width * 1000, nearest * 1000, reads))
  }
}
