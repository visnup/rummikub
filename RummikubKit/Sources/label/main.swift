import Foundation
import ImageIO
import RummikubKit
import UniformTypeIdentifiers

// Writes every tile read in each capture to `<capture>.tiles.json`, as boxes to check by hand. A tile's value is
// confirmed where it agrees with the truth, closest matches first, and in a full set its neighbors agree too. A file
// with any tile labeled by hand is left alone. With a second directory, also writes each capture with its tiles drawn
// on for checking, unconfirmed ones as jokers.
//   label <captures> [<overlays>]
let captures = URL(filePath: CommandLine.arguments[1])
let overlays = CommandLine.arguments.dropFirst(2).first.map { URL(filePath: $0) }
var labeled = 0, confirmedCount = 0, total = 0
for url in try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
  .filter({ $0.pathExtension == "png" }).sorted(by: { $0.path < $1.path })
{
  let base = url.deletingPathExtension()
  let output = base.appendingPathExtension("tiles.json")
  if let data = try? Data(contentsOf: output),
    let tiles = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
    tiles.contains(where: { $0["source"] as? String == "hand" })
  {
    print(base.lastPathComponent, "labeled by hand, skipped")
    continue
  }
  let lines = try String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8).split(separator: "\n")
  var left = [Tile: Int]()
  for tile in Tile.parse(lines.dropFirst().joined(separator: " ")) { left[tile, default: 0] += 1 }
  let truth = left.values.reduce(0, +)
  let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
  // With no tiles in the truth, everything read is a false read.
  let read = truth == 0 ? [] : Recognizer.tiles(in: image)
  let agreed = read.filter { detection in
    guard left[detection.tile, default: 0] > 0 else { return false }
    left[detection.tile]! -= 1
    return true
  }
  // A full set's truth holds every tile, so agreeing with it proves little; laid out in rows, neighbors can. A hand's
  // or a meld's truth is short enough that agreeing with it is proof.
  let notes = (try? Data(contentsOf: base.appendingPathExtension("json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  let sure =
    notes?["layout"] as? String == "Full set"
    ? Set(confirmed(agreed, width: image.width, height: image.height)) : Set(agreed)
  let json = read.map { detection -> [String: Any] in
    let f = detection.frame
    return [
      "tile": detection.tile.description, "frame": [f.minX, f.minY, f.width, f.height], "turns": detection.turns,
      "source": "auto", "confirmed": sure.contains(detection),
    ]
  }
  try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: output)
  labeled += agreed.count
  confirmedCount += sure.count
  total += truth
  print(base.lastPathComponent, agreed.count, sure.count, "of", truth)
  if let overlays {
    let destination = CGImageDestinationCreateWithURL(
      overlays.appending(path: base.lastPathComponent + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      destination,
      Render.overlay(image, read.map { .label($0.frame, sure.contains($0) ? $0.tile : .joker) }), nil)
    CGImageDestinationFinalize(destination)
  }
}
print("labeled", labeled, "confirmed", confirmedCount, "of", total)

/// Tiles laid out in runs, one color to a row: confirmed when a tile beside one continues its run in its color, and
/// one above or below has its value, both in its own upright frame.
func confirmed(_ detections: [Detection], width: Int, height: Int) -> [Detection] {
  func upright(_ d: Detection) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    let x = d.frame.midX, y = d.frame.midY, w = CGFloat(width), h = CGFloat(height)
    return switch d.turns {
    case 1: (h - y, x, d.frame.height, d.frame.width)
    case 2: (w - x, h - y, d.frame.width, d.frame.height)
    case 3: (y, w - x, d.frame.height, d.frame.width)
    default: (x, y, d.frame.width, d.frame.height)
    }
  }
  return detections.filter { d in
    guard let value = d.tile.value else { return false }
    let c = upright(d)
    let others = detections.filter { $0 != d && $0.turns == d.turns }
    let beside = others.contains { o in
      guard let v = o.tile.value, o.tile.color == d.tile.color, abs(v - value) == 1 else { return false }
      let p = upright(o)
      return abs(p.y - c.y) < c.h / 2 && abs(p.x - c.x) < c.w * 1.7 && (p.x - c.x) * CGFloat(v - value) > 0
    }
    let stacked = others.contains { o in
      let p = upright(o)
      return o.tile.value == value && abs(p.x - c.x) < c.w / 2 && abs(p.y - c.y) < c.h * 2.2
    }
    return beside && stacked
  }
}
