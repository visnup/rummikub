#if os(macOS)
  import CoreML
  import Foundation
  import ImageIO
  import RummikubKit

  // Writes what Values reads into every unconfirmed box of every capture: its tile, orientation, and how sure it is
  // ("odds"), for the labeler to confirm. Confirmed boxes are left alone.
  //   fill <captures> [<Values.mlpackage>]
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let model = CommandLine.arguments.count > 2 ? URL(filePath: CommandLine.arguments[2]) : captures.appending(path: "Values.mlpackage")
  let values = try Classifier(model: MLModel(contentsOf: MLModel.compileModel(at: model)))
  let files = try [captures, captures.appending(path: "unlabeled")].flatMap { folder in
    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".tiles.json") }
  }.sorted { $0.path < $1.path }

  var filled = 0
  for file in files {
    var labels = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
    let open = labels.indices.filter { labels[$0]["confirmed"] as? Bool != true }
    let png = URL(filePath: file.path.replacingOccurrences(of: ".tiles.json", with: ".png"))
    guard !open.isEmpty, let source = CGImageSourceCreateWithURL(png as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { continue }
    let frames = open.map { i in
      let f = labels[i]["frame"] as! [Double]
      return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
    let reads = try values.tiles(in: image, boxes: frames, least: 0)
    for (i, frame) in zip(open, frames) {
      guard let read = reads.first(where: { $0.frame == frame }) else { continue }
      // The orientation most likely over every tile, then the tile most likely at it.
      let sums = (0..<4).map { k in read.turned.values.reduce(0) { $0 + $1[k] } }
      let turns = sums.indices.max { sums[$0] < sums[$1] }!
      guard let (tile, p) = read.turned.mapValues({ $0[turns] }).max(by: { $0.value < $1.value }), sums[turns] > 0
      else { continue }
      labels[i]["tile"] = tile.description
      labels[i]["turns"] = turns
      labels[i]["odds"] = Double((p / sums[turns] * 100).rounded() / 100)
      filled += 1
    }
    try JSONSerialization.data(withJSONObject: labels, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    print(file.lastPathComponent, open.count, separator: "\t")
  }
  print("filled", filled)
#endif
