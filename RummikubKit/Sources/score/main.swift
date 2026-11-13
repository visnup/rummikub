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
  let environment = ProcessInfo.processInfo.environment
  // TILES=<package> scores another finder.
  let tiles = environment["TILES"].map { URL(filePath: $0) } ?? captures.appending(path: "Tiles.mlpackage")
  var finder = try Finder(model: MLModel(contentsOf: MLModel.compileModel(at: tiles)))
  // CONFIDENCE=0.4 moves the finder's cutoff, for detectors whose scores run lower.
  if let confidence = environment["CONFIDENCE"].flatMap(Float.init) { finder.confidence = confidence }
  // ENOUGH=60 skips the crops when every box the whole image finds is 60 px or more.
  finder.enough = environment["ENOUGH"].flatMap(Double.init)
  var regions = 0, frames = 0
  // Tiles out of scope aren't counted, and a box on one isn't extra. MIN=40 moves the cutoff, MIN=0 counts them all.
  let smallest = environment["MIN"].flatMap(Double.init) ?? Finder.smallest
  let values = captures.appending(path: "Values.mlpackage")
  let classifier = FileManager.default.fileExists(atPath: values.path)
    ? try Classifier(model: MLModel(contentsOf: MLModel.compileModel(at: values))) : nil
  let done = ((try? String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)

  /// Each kind of error, by where it happens. The finder: a tile `missed` (no box), a `phantom` box (on no tile), a
  /// `duplicate` box (a second on a tile already found). Then reading, of the confirmed tiles found, as the app reads
  /// them (melds made valid at the table): read `correctly`, `misread` (another value, a 6 for a 9 among them), or
  /// `unread` (Values not sure enough). A `phantom read` is a reading on a phantom or duplicate box. Orientation isn't
  /// scored: nothing downstream uses it, and where it matters, 6 and 9, it's a misread.
  struct Score {
    var tiles = 0, found = 0, phantom = 0, duplicate = 0
    var confirmed = 0, correctly = 0, misread = 0, unread = 0, phantomRead = 0

    static let header = ["tiles", "found", "missed", "phantom", "duplicate", "confirmed", "read correctly", "misread",
      "unread", "phantom read"]
    var columns: [Int] {
      [tiles, found, tiles - found, phantom, duplicate, confirmed, correctly, misread, unread, phantomRead]
    }

    static func += (a: inout Score, b: Score) {
      a = Score(
        tiles: a.tiles + b.tiles, found: a.found + b.found, phantom: a.phantom + b.phantom,
        duplicate: a.duplicate + b.duplicate, confirmed: a.confirmed + b.confirmed, correctly: a.correctly + b.correctly,
        misread: a.misread + b.misread, unread: a.unread + b.unread, phantomRead: a.phantomRead + b.phantomRead)
    }
  }
  var total = Score()
  /// Each value's confirmed tiles in scope, and how many the finder missed, Values misread (and as what) or left
  /// unread, for the labeler's values page.
  struct PerTile: Encodable {
    var tiles = 0, missed = 0, misread = 0, unread = 0
    var readAs = [String: Int]()
  }
  var byTile = [String: PerTile]()
  print((["capture"] + Score.header).joined(separator: "\t"))
  /// Of the captures with rack tiles marked, the rack's tiles, those Values says are on a rack, and the table's it
  /// says are too.
  var rackTiles = 0, rackKept = 0, tableKept = 0
  for name in done.filter(Finder.isHeldOut).sorted() {
    let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]
    let truth = labels.map { CGRect(xywh: $0["frame"] as! [Double]) }
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let (boxes, used) = try finder.find(in: image)
    regions += used
    frames += 1

    let lines = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
      .split(separator: "\n")
    let small = { (r: CGRect) in !Finder.inScope(r, width: image.width, height: image.height, smallest: smallest) }
    // Each confirmed box's value is the truth for that box.
    let known = Dictionary(uniqueKeysWithValues: labels.indices.compactMap { i -> (Int, Tile)? in
      guard labels[i]["confirmed"] as? Bool == true, !small(truth[i]), let tile = Tile(labels[i]["tile"] as! String) else { return nil }
      return (i, tile)
    })
    var s = Score(tiles: truth.count { !small($0) }, confirmed: known.count)
    // Each finder box's tile, nil for a phantom or duplicate.
    var left = Set(truth.indices), tileOf = [Int?]()
    for box in boxes {
      let best = { (pool: Set<Int>) in pool.max { Finder.overlap(truth[$0], box) < Finder.overlap(truth[$1], box) } }
      if let i = best(left), Finder.overlap(truth[i], box) > 0.5 {
        if !small(truth[i]) { s.found += 1 }
        left.remove(i)
        tileOf.append(i)
      } else {
        let taken = Set(truth.indices).subtracting(left)
        if let i = best(taken), Finder.overlap(truth[i], box) > 0.5 { s.duplicate += 1 }
        else if !small(box), !(best(Set(truth.indices)).map { small(truth[$0]) && Finder.overlap(truth[$0], box) > 0 } ?? false) {
          s.phantom += 1
          // PHANTOMS=1 prints each phantom box.
          if environment["PHANTOMS"] != nil { print("phantom", name, box) }
        }
        tileOf.append(nil)
      }
    }
    for (i, tile) in known {
      byTile[tile.description, default: PerTile()].tiles += 1
      if left.contains(i) { byTile[tile.description]!.missed += 1 }
    }
    func score(_ readings: [Detection]) {
      for (box, i) in zip(boxes, tileOf) {
        let read = readings.first { $0.frame == box }
        guard let i else {
          if read != nil { s.phantomRead += 1 }
          continue
        }
        guard let tile = known[i] else { continue }
        if let read, read.tile != tile {
          s.misread += 1
          byTile[tile.description]!.misread += 1
          byTile[tile.description]!.readAs[read.tile.description, default: 0] += 1
        } else if read != nil {
          s.correctly += 1
        } else {
          s.unread += 1
          byTile[tile.description]!.unread += 1
        }
      }
    }
    let reads = try classifier?.tiles(in: image, boxes: boxes)
    let rack = Set(labels.indices.filter { labels[$0]["rack"] as? Bool == true })
    if !rack.isEmpty, let reads {
      rackTiles += rack.count
      for (box, i) in zip(boxes, tileOf) {
        guard let i, (reads.first { $0.frame == box }?.rack ?? 0) >= 0.5 else { continue }
        if rack.contains(i) { rackKept += 1 } else { tableKept += 1 }
      }
    }
    if let classifier {
      let classified = reads!
      // READS=1 prints each confirmed tile's reading, for a breakdown of what's misread.
      if environment["READS"] != nil {
        let all = Recognizer.turned(try classifier.tiles(in: image, boxes: boxes, least: 0))
        for (t, frame) in zip(labels, truth) where t["confirmed"] as? Bool == true {
          guard let tile = Tile(t["tile"] as! String) else { continue }
          let read = all.max { Finder.overlap($0.frame, frame) < Finder.overlap($1.frame, frame) }
          guard let read, Finder.overlap(read.frame, frame) > 0.5 else {
            print("read", name, lines[0], tile, "-", 0, 0, Int(frame.height), t["turns"] as? Int ?? 0, separator: "\t")
            continue
          }
          print("read", name, lines[0], tile, read.tile, read.odds[read.tile] ?? 0, read.odds[tile] ?? 0,
            Int(frame.height), t["turns"] as? Int ?? 0, read.turns, separator: "\t")
        }
      }
      // Near how the app reads: the tiles Values says lie on the table as valid melds, the rack's as read.
      let turned = Recognizer.turned(classified)
      let onRack = { (d: Detection) in (d.rack ?? 0) >= 0.5 }
      score(Recognizer.valid(Recognizer.melds(turned.filter { !onRack($0) })).flatMap(\.self) + turned.filter(onRack))
    }
    print(([name] + s.columns.map(String.init)).joined(separator: "\t"))
    total += s
  }
  print((["total"] + total.columns.map(String.init)).joined(separator: "\t"))
  print("regions", regions, "in", frames, "frames")
  if rackTiles > 0 { print("rack tiles", "\(rackKept)/\(rackTiles) on a rack, +\(tableKept) table", separator: "\t") }
  // Only for the models the app has, not one being compared.
  if environment["TILES"] == nil, classifier != nil {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(byTile).write(to: captures.appending(path: ".score.json"))
  }
#endif
