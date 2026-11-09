#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Scores the finder, and with a `Values.mlpackage` beside the captures the finder's boxes read by it, on the
  // held-out captures whose boxes are done, which training never sees. A tile is found when a box overlaps its true
  // box by half.
  //   score <captures>
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let package = captures.appending(path: "Tiles.mlpackage")
  let tiles = FileManager.default.fileExists(atPath: package.path) ? package : captures.appending(path: "Tiles.mlmodel")
  var finder = try Finder(model: MLModel(contentsOf: MLModel.compileModel(at: tiles)))
  // WHOLE=1 looks in the whole image only, without crops.
  finder.cropped = (ProcessInfo.processInfo.environment["WHOLE"] ?? "").isEmpty
  // SIDE=0.5 crops squares half the short side of the image, rather than all of it.
  if let side = ProcessInfo.processInfo.environment["SIDE"].flatMap(Double.init) { finder.side = side }
  // ENOUGH=60 skips the crops when every box the whole image finds is 60 px or more.
  finder.enough = ProcessInfo.processInfo.environment["ENOUGH"].flatMap(Double.init)
  var regions = 0, frames = 0
  // Tiles out of scope aren't counted, and a box on one isn't extra. MIN=40 moves the cutoff, MIN=0 counts them all.
  let smallest = ProcessInfo.processInfo.environment["MIN"].flatMap(Double.init) ?? Finder.smallest
  let values = captures.appending(path: "Values.mlpackage")
  let classifier = FileManager.default.fileExists(atPath: values.path)
    ? try Classifier(model: MLModel(contentsOf: MLModel.compileModel(at: values))) : nil
  let done = ((try? String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)

  struct Score {
    var tiles = 0, found = 0, extraBoxes = 0, valued = 0, classified = 0, extraClassified = 0, valid = 0, extraValid = 0

    static func += (a: inout Score, b: Score) {
      a = Score(
        tiles: a.tiles + b.tiles, found: a.found + b.found, extraBoxes: a.extraBoxes + b.extraBoxes,
        valued: a.valued + b.valued, classified: a.classified + b.classified,
        extraClassified: a.extraClassified + b.extraClassified, valid: a.valid + b.valid, extraValid: a.extraValid + b.extraValid)
    }

    var columns: [String] {
      ["\(found)/\(tiles) +\(extraBoxes)", "\(classified)/\(valued) +\(extraClassified)", "\(valid)/\(valued) +\(extraValid)"]
    }
  }
  var total = Score()
  print("capture", "found/tiles +extra", "classified +extra", "valid melds +extra", separator: "\t")
  for name in done.filter(Finder.isHeldOut).sorted() {
    let truth = try (JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]).map { t in
        let f = t["frame"] as! [Double]
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
      }
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let (boxes, used) = try finder.find(in: image)
    regions += used
    frames += 1

    let lines = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
      .split(separator: "\n")
    let written = Dictionary(Tile.parse(lines.dropFirst().joined(separator: " ")).map { ($0, 1) }, uniquingKeysWith: +)
    let small = { (r: CGRect) in !Finder.inScope(r, width: image.width, height: image.height, smallest: smallest) }
    var s = Score(tiles: truth.count { !small($0) }, valued: written.values.reduce(0, +))
    var left = truth
    for box in boxes {
      if let i = left.indices.max(by: { Finder.overlap(left[$0], box) < Finder.overlap(left[$1], box) }),
        Finder.overlap(left[i], box) > 0.5
      {
        if !small(left[i]) { s.found += 1 }
        left.remove(at: i)
      } else {
        s.extraBoxes += 1
      }
    }
    /// Tiles read right and extra, against the truth written for the capture.
    func score(_ readings: [Detection]) -> (right: Int, extra: Int) {
      var left = written
      let right = readings.filter { d in
        guard left[d.tile, default: 0] > 0 else { return false }
        left[d.tile]! -= 1
        return true
      }.count
      return (right, readings.count - right)
    }
    if let classifier {
      let classified = try classifier.tiles(in: image, boxes: boxes)
      // READS=1 prints each confirmed tile's reading, for a breakdown of what's misread.
      if ProcessInfo.processInfo.environment["READS"] != nil {
        let all = Recognizer.turned(try classifier.tiles(in: image, boxes: boxes, least: 0))
        let tiles = try JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
          as! [[String: Any]]
        for t in tiles where t["confirmed"] as? Bool == true {
          guard let tile = Tile(t["tile"] as! String) else { continue }
          let f = t["frame"] as! [Double]
          let frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
          let read = all.max { Finder.overlap($0.frame, frame) < Finder.overlap($1.frame, frame) }
          guard let read, Finder.overlap(read.frame, frame) > 0.5 else {
            print("read", name, lines[0], tile, "-", 0, 0, Int(frame.height), t["turns"] as? Int ?? 0, separator: "\t")
            continue
          }
          print("read", name, lines[0], tile, read.tile, read.odds[read.tile] ?? 0, read.odds[tile] ?? 0,
            Int(frame.height), t["turns"] as? Int ?? 0, read.turns, separator: "\t")
        }
      }
      (s.classified, s.extraClassified) = score(classified)
      let table = lines.first?.hasPrefix("table") ?? false
      let turned = Recognizer.turned(classified)
      (s.valid, s.extraValid) = score(table ? Recognizer.valid(Recognizer.melds(turned)).flatMap(\.self) : turned)
    }
    print(([name] + s.columns).joined(separator: "\t"))
    total += s
  }
  print((["total"] + total.columns).joined(separator: "\t"))
  print("regions", regions, "in", frames, "frames")
#endif
