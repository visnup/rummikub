import CoreGraphics
import Foundation
import simd

/// An AR recording's frames: a log (`<start>.jsonl`, a frame a line, as the app writes it while recording) or a
/// capture's `ar.history`.
public struct Recording: Sendable {
  public struct Frame: Sendable {
    /// Seconds since 1970.
    public let time: Double
    /// "table" or "rack".
    public let looking: String
    /// ARKit's tracking state, "normal" or why it's limited.
    public let tracking: String
    public let pose: Pose
    public let mask: World.Mask?
    public let detections: [Detection]
  }

  public let frames: [Frame]

  public init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url)
    let lines: [[String: Any]] =
      if url.pathExtension == "jsonl" {
        try data.split(separator: UInt8(ascii: "\n")).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
      } else {
        ((try JSONSerialization.jsonObject(with: data) as! [String: Any])["ar"] as? [String: Any])?["history"]
          as? [[String: Any]] ?? []
      }
    func matrix4(_ v: [Float]) -> simd_float4x4 {
      simd_float4x4(columns: (SIMD4(v[0..<4]), SIMD4(v[4..<8]), SIMD4(v[8..<12]), SIMD4(v[12..<16])))
    }
    frames = lines.map { frame in
      let k = (frame["intrinsics"] as! [NSNumber]).map(\.floatValue), size = frame["resolution"] as! [Double]
      let pose = Pose(
        intrinsics: simd_float3x3(columns: (SIMD3(k[0..<3]), SIMD3(k[3..<6]), SIMD3(k[6..<9]))),
        resolution: CGSize(width: size[0], height: size[1]),
        transform: matrix4((frame["transform"] as! [NSNumber]).map(\.floatValue)),
        plane: (frame["plane"] as? [NSNumber]).map { matrix4($0.map(\.floatValue)) })
      let detections = (frame["detections"] as! [[String: Any]]).map { d in
        let f = d["frame"] as! [Double]
        let odds = (d["odds"] as? [String: NSNumber] ?? [:]).reduce(into: [Tile: Float]()) { $0[Tile($1.key)!] = $1.value.floatValue }
        return Detection(
          tile: Tile(d["tile"] as! String)!, frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]),
          turns: d["turns"] as? Int ?? 0, odds: odds, rack: (d["rack"] as? NSNumber)?.floatValue)
      }
      let mask = (frame["mask"] as? [String: Any]).map {
        World.Mask(width: $0["width"] as! Int, height: $0["height"] as! Int,
          bytes: [UInt8](Data(base64Encoded: $0["bytes"] as! String)!))
      }
      return Frame(time: frame["time"] as! Double, looking: frame["looking"] as? String ?? "",
        tracking: frame["tracking"] as? String ?? "normal", pose: pose, mask: mask,
        detections: detections)
    }
  }
}
