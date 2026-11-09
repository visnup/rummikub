#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Lists where the models disagree with each done capture's labels, for the labeler to show: boxes the finder
  // doesn't find, boxes it finds that aren't labeled, and confirmed values that Values reads as
  // another tile at least .8 sure. Training captures too, since a label the models can't fit is likely wrong.
  //   check <captures>  → <captures>/.check.json
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let compiled = { (name: String) in try MLModel(contentsOf: MLModel.compileModel(at: captures.appending(path: name))) }
  let finder = try Finder(model: compiled("Tiles.mlpackage"))
  let values = try Classifier(model: compiled("Values.mlpackage"))
  let done = try String(contentsOf: captures.appending(path: "boxed.txt"), encoding: .utf8).split(separator: "\n")
  let rect = { (f: [Double]) in CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) }
  let array = { (r: CGRect) in [r.minX, r.minY, r.width, r.height].map { Double(($0 * 10).rounded() / 10) } }

  var out = [String: Any]()
  for (n, name) in done.map(String.init).enumerated() {
    let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: name + ".tiles.json")))
      as! [[String: Any]]
    let url = captures.appending(path: name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let truth = labels.map { rect($0["frame"] as! [Double]) }

    var left = Array(truth.indices), extra = [[Double]]()
    for box in try finder.tiles(in: image) {
      if let i = left.max(by: { Finder.overlap(truth[$0], box) < Finder.overlap(truth[$1], box) }),
        Finder.overlap(truth[i], box) > 0.5
      {
        left.removeAll { $0 == i }
      } else {
        extra.append(array(box))
      }
    }

    let confirmed = labels.indices.filter { labels[$0]["confirmed"] as? Bool == true && Tile(labels[$0]["tile"] as! String) != nil }
    var misread = [[String: Any]]()
    for i in confirmed {
      guard let read = try values.tiles(in: image, boxes: [truth[i]], least: 0.8).first else { continue }
      if read.tile.description != labels[i]["tile"] as! String {
        misread.append(["frame": array(truth[i]), "tile": labels[i]["tile"]!, "read": read.tile.description,
          "odds": (read.odds[read.tile]! * 100).rounded() / 100])
      }
    }
    // A box on a tile out of scope isn't extra, nor is one the finder misses there missed.
    left.removeAll { !Finder.inScope(truth[$0], width: image.width, height: image.height) }
    if !left.isEmpty || !extra.isEmpty || !misread.isEmpty {
      out[name] = ["missed": left.map { array(truth[$0]) }, "extra": extra, "values": misread]
    }
    print(n + 1, done.count, name, left.count, extra.count, misread.count, separator: "\t")
  }
  try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    .write(to: captures.appending(path: ".check.json"))
#endif
