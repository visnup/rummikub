#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Scores the finder and the reader on the held-out captures whose boxes are done, which training never sees. A
  // tile is found when a box overlaps its true box by half. Reads with and without dropping readings outside the
  // finder's boxes, as the app does.
  //   score <captures> [<model>]
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let model = CommandLine.arguments.dropFirst(2).first.map { URL(filePath: $0) } ?? captures.appending(path: "Tiles.mlmodel")
  let finder = try Finder(model: MLModel(contentsOf: MLModel.compileModel(at: model)))
  let done = ((try? String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)

  struct Score {
    var tiles = 0, found = 0, extraBoxes = 0, valued = 0, read = 0, filtered = 0, extraReads = 0, extraFiltered = 0
  }
  var total = Score()
  print("capture", "found/tiles +extra", "read/valued +extra", "with finder +extra", separator: "\t")
  for name in done.filter(Finder.isHeldOut).sorted() {
    let truth = try (JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]).map { t in
        let f = t["frame"] as! [Double]
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
      }
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let boxes = try finder.tiles(in: image).map(\.box)
    let readings = Recognizer.tiles(in: image)
    let filtered = readings.filter { d in boxes.contains { $0.intersects(d.frame) } }

    let lines = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
      .split(separator: "\n")
    let written = Dictionary(Tile.parse(lines.dropFirst().joined(separator: " ")).map { ($0, 1) }, uniquingKeysWith: +)
    var s = Score(tiles: truth.count, valued: written.values.reduce(0, +))
    var left = truth
    for box in boxes {
      if let i = left.indices.max(by: { Finder.overlap(left[$0], box) < Finder.overlap(left[$1], box) }),
        Finder.overlap(left[i], box) > 0.5
      {
        left.remove(at: i)
        s.found += 1
      } else {
        s.extraBoxes += 1
      }
    }
    /// Tiles read right and extra, against the truth written for the capture. Not against values in `tiles.json`,
    /// which are mostly the reader's own.
    func score(_ readings: [Detection]) -> (right: Int, extra: Int) {
      var left = written
      let right = readings.filter { d in
        guard left[d.tile, default: 0] > 0 else { return false }
        left[d.tile]! -= 1
        return true
      }.count
      return (right, readings.count - right)
    }
    (s.read, s.extraReads) = score(readings)
    (s.filtered, s.extraFiltered) = score(filtered)
    print(
      name, "\(s.found)/\(s.tiles) +\(s.extraBoxes)", "\(s.read)/\(s.valued) +\(s.extraReads)",
      "\(s.filtered)/\(s.valued) +\(s.extraFiltered)", separator: "\t")
    total.tiles += s.tiles
    total.found += s.found
    total.extraBoxes += s.extraBoxes
    total.valued += s.valued
    total.read += s.read
    total.filtered += s.filtered
    total.extraReads += s.extraReads
    total.extraFiltered += s.extraFiltered
  }
  print(
    "total", "\(total.found)/\(total.tiles) +\(total.extraBoxes)", "\(total.read)/\(total.valued) +\(total.extraReads)",
    "\(total.filtered)/\(total.valued) +\(total.extraFiltered)", separator: "\t")
#endif
