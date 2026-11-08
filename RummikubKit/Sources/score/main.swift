#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Scores the finder and the reader on the held-out captures whose boxes are done, which training never sees. A
  // tile is found when a box overlaps its true box by half. Reads with and without dropping readings outside the
  // finder's boxes, as the app does, and with a `Values.mlmodel` beside the captures, by classifying the boxes.
  //   score <captures>
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let package = captures.appending(path: "Tiles.mlpackage")
  let tiles = FileManager.default.fileExists(atPath: package.path) ? package : captures.appending(path: "Tiles.mlmodel")
  let finder = try Finder(model: MLModel(contentsOf: MLModel.compileModel(at: tiles)))
  let values = captures.appending(path: "Values.mlmodel")
  let classifier = FileManager.default.fileExists(atPath: values.path)
    ? try Classifier(model: MLModel(contentsOf: MLModel.compileModel(at: values))) : nil
  let done = ((try? String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)

  struct Score {
    var tiles = 0, found = 0, extraBoxes = 0, valued = 0, read = 0, filtered = 0, extraReads = 0, extraFiltered = 0
    var classified = 0, extraClassified = 0, valid = 0, extraValid = 0

    static func += (a: inout Score, b: Score) {
      a = Score(
        tiles: a.tiles + b.tiles, found: a.found + b.found, extraBoxes: a.extraBoxes + b.extraBoxes,
        valued: a.valued + b.valued, read: a.read + b.read, filtered: a.filtered + b.filtered,
        extraReads: a.extraReads + b.extraReads, extraFiltered: a.extraFiltered + b.extraFiltered,
        classified: a.classified + b.classified, extraClassified: a.extraClassified + b.extraClassified,
        valid: a.valid + b.valid, extraValid: a.extraValid + b.extraValid)
    }

    var columns: [String] {
      ["\(found)/\(tiles) +\(extraBoxes)", "\(read)/\(valued) +\(extraReads)", "\(filtered)/\(valued) +\(extraFiltered)",
        "\(classified)/\(valued) +\(extraClassified)", "\(valid)/\(valued) +\(extraValid)"]
    }
  }
  var total = Score()
  print("capture", "found/tiles +extra", "read/valued +extra", "with finder +extra", "classified +extra", "valid melds +extra", separator: "\t")
  for name in done.filter(Finder.isHeldOut).sorted() {
    let truth = try (JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]).map { t in
        let f = t["frame"] as! [Double]
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
      }
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let boxes = try finder.tiles(in: image)
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
    if let classifier {
      let classified = try classifier.tiles(in: image, boxes: boxes)
      (s.classified, s.extraClassified) = score(classified)
      let table = lines.first?.hasPrefix("table") ?? false
      (s.valid, s.extraValid) = score(table ? Recognizer.valid(Recognizer.melds(classified)).flatMap(\.self) : classified)
    }
    print(([name] + s.columns).joined(separator: "\t"))
    total += s
  }
  print((["total"] + total.columns).joined(separator: "\t"))
#endif
