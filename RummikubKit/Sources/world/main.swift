// Replays AR captures' frame history (`ar.history`) through `World`: each frame's reads and places, then the table
// and rack it ends with, as melds seen from the last frame.
//   swift run world ../Captures/unlabeled/<time>.json ...
import Foundation
import RummikubKit
import simd

func matrix4(_ v: [Float]) -> simd_float4x4 {
  simd_float4x4(columns: (SIMD4(v[0..<4]), SIMD4(v[4..<8]), SIMD4(v[8..<12]), SIMD4(v[12..<16])))
}

for path in CommandLine.arguments.dropFirst() {
  let notes = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: path))) as! [String: Any]
  guard let history = (notes["ar"] as? [String: Any])?["history"] as? [[String: Any]] else { continue }
  print("\(URL(filePath: path).lastPathComponent) (\(notes["looking"] ?? "?"))")
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
      return Detection(
        tile: Tile(d["tile"] as! String)!, frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]),
        turns: d["turns"] as? Int ?? 0, rack: (d["rack"] as? NSNumber)?.floatValue)
    }
    let ids = world.add(detections, pose: pose)
    if pose.plane != nil { last = pose }
    print(String(format: "  %.1f s  %2d read, %2d placed, %2d places, %2d sure", (frame["time"] as! Double) - (history[0]["time"] as! Double),
      detections.count, ids.count { $0 != nil }, world.places.count, world.places.count(where: \.sure)))
  }
  guard let last else { continue }
  let seen = world.detections(from: last)
  let rack = seen.filter(\.place.isRack).map(\.detection), table = seen.filter { !$0.place.isRack }.map(\.detection)
  func line(_ ds: [Detection]) -> String { ds.map(\.tile.description).joined(separator: " ") }
  print("  rack:  " + line(Recognizer.melds(rack).joined().map(\.self)))
  print("  table: " + Recognizer.valid(Recognizer.melds(table)).map(line).joined(separator: ", "))
  for (place, _) in seen.sorted(by: { $0.place.seen > $1.place.seen }) {
    let reads = place.reads.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value))" }.joined(separator: " ")
    let nearest = world.places.filter { $0.id != place.id }.map { distance($0.point, place.point) }.min() ?? 0
    print(String(format: "    #%-3d seen %2d  rack %.2f  width %2.0f mm, %2.0f mm from the next  %@", place.id, place.seen,
      place.onRack ?? -1, place.width * 1000, nearest * 1000, reads))
  }
}
