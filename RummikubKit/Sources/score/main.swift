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
  // BOXES=<folder> scores boxes found elsewhere, `<name>.json` a capture, each box [x, y, width, height] in pixels.
  let found = environment["BOXES"].map { URL(filePath: $0) }
  // WHOLE=1 looks in the whole image only, without crops.
  finder.cropped = (environment["WHOLE"] ?? "").isEmpty
  // SIDE=0.5 crops squares half the short side of the image, rather than all of it.
  if let side = environment["SIDE"].flatMap(Double.init) { finder.side = side }
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
  print((["capture"] + Score.header).joined(separator: "\t"))
  /// The rack's tiles kept, and the table's let through, by `Finder.nearest` and then by Values' rack-or-table; and,
  /// of `nearest`'s, by `Standing.taper` alone, with how many it found no corners for.
  struct Rack: CustomStringConvertible {
    var tiles = 0, nearest = 0, nearestTable = 0, standing = 0, standingTable = 0, tapered = 0, taperedTable = 0,
      cornerless = 0

    static func += (a: inout Rack, b: Rack) {
      a = Rack(
        tiles: a.tiles + b.tiles, nearest: a.nearest + b.nearest, nearestTable: a.nearestTable + b.nearestTable,
        standing: a.standing + b.standing, standingTable: a.standingTable + b.standingTable,
        tapered: a.tapered + b.tapered, taperedTable: a.taperedTable + b.taperedTable,
        cornerless: a.cornerless + b.cornerless)
    }

    var description: String {
      "nearest \(nearest)/\(tiles) +\(nearestTable) table, then on a rack \(standing)/\(tiles) +\(standingTable) table, "
        + "or tapered \(tapered)/\(tiles) +\(taperedTable) table (\(cornerless) without corners)"
    }
  }
  // TAPER=1.1 is how much longer a tile's top edge must come out than its bottom to stand.
  let taperCutoff = environment["TAPER"].flatMap(Double.init) ?? 1.08
  var rackTotal = Rack()
  for name in done.filter(Finder.isHeldOut).sorted() {
    let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]
    let truth = labels.map { t in
      let f = t["frame"] as! [Double]
      return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let (boxes, used) = try found.map { folder in
      let frames = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: name + ".json"))) as! [[Double]]
      return (frames.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }, 0)
    } ?? finder.find(in: image)
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
        if let i = best(taken), Finder.overlap(truth[i], box) > 0.5 { s.duplicate += 1 } else { s.phantom += 1 }
        tileOf.append(nil)
      }
    }
    func score(_ readings: [Detection]) {
      for (box, i) in zip(boxes, tileOf) {
        let read = readings.first { $0.frame == box }
        guard let i else {
          if read != nil { s.phantomRead += 1 }
          continue
        }
        guard let tile = known[i] else { continue }
        if let read {
          if read.tile != tile { s.misread += 1 } else { s.correctly += 1 }
        } else {
          s.unread += 1
        }
      }
    }
    let reads = try classifier?.tiles(in: image, boxes: boxes)
    // At the rack the app keeps only `Finder.nearest`'s boxes, then the reads Values says are on a rack: how many of the
    // rack's tiles survive each, and how many of those marked background, the table behind it, do too. Only rack
    // captures with background marked, since unmarked ones may not have been looked at.
    let background = Set(labels.indices.filter { labels[$0]["background"] as? Bool == true })
    if lines.first?.hasPrefix("rack") == true, !background.isEmpty {
      var left = Set(truth.indices)
      let rack = Set(truth.indices).subtracting(background)
      var n = Rack(tiles: rack.count)
      // The camera from the capture's notes: ARKit's intrinsics, else the lens's field of view at its zoom.
      let notes = try JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
        as! [String: Any]
      let gravity = (notes["gravity"] as? [Double]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
      let camera = notes["camera"] as? [String: Any]
      let lens: (focal: Double, center: CGPoint)? =
        if let k = (notes["ar"] as? [String: Any])?["intrinsics"] as? [Double] {
          (k[0], CGPoint(x: Double(image.width) - k[7], y: k[6]))
        } else if let fov = camera?["fieldOfView"] as? Double {
          (Double(image.height) / 2 / tan(fov * .pi / 360) * (camera?["zoom"] as? Double ?? 1),
           CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2))
        } else { nil }
      for box in Finder.nearest(boxes) {
        guard let i = left.max(by: { Finder.overlap(truth[$0], box) < Finder.overlap(truth[$1], box) }),
          Finder.overlap(truth[i], box) > 0.5
        else { continue }
        left.remove(i)
        let standing = (reads?.first { $0.frame == box }?.rack ?? 1) >= 0.5
        let taper = Standing.corners(in: image, box: box).flatMap { corners in
          gravity.flatMap { g in lens.flatMap { Standing.taper(corners, gravity: g, focal: $0.focal, center: $0.center) } }
        }
        // TAPERS=1 prints each tile's taper.
        if environment["TAPERS"] != nil {
          print("taper", name, rack.contains(i) ? "rack" : "table", taper.map { String(format: "%.3f", $0) } ?? "-",
            Int(box.height), standing ? "on a rack" : "", separator: "\t")
        }
        if taper == nil { n.cornerless += 1 }
        if let taper, taper >= taperCutoff { if rack.contains(i) { n.tapered += 1 } else { n.taperedTable += 1 } }
        if rack.contains(i) {
          n.nearest += 1
          if standing { n.standing += 1 }
        } else {
          n.nearestTable += 1
          if standing { n.standingTable += 1 }
        }
      }
      print("rack", name, n.description, separator: "\t")
      rackTotal += n
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
      let table = lines.first?.hasPrefix("table") ?? false
      let turned = Recognizer.turned(classified)
      score(table ? Recognizer.valid(Recognizer.melds(turned)).flatMap(\.self) : turned)
    }
    print(([name] + s.columns.map(String.init)).joined(separator: "\t"))
    total += s
  }
  print((["total"] + total.columns.map(String.init)).joined(separator: "\t"))
  print("regions", regions, "in", frames, "frames")
  if rackTotal.tiles > 0 { print("rack tiles kept", rackTotal.description, separator: "\t") }
#endif
