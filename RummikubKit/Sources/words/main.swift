#if os(macOS)
  import Foundation
  import ImageIO
  import Vision

  // Flags captures with readable words, which could be personal, for a look before `make upload`: a line of three or
  // more words of two letters or more. Tile numerals and lone key legends don't count. Each capture is read once;
  // names checked go in `.words.txt`, flagged ones with their text in `review.txt`.
  //   words <captures>
  setvbuf(stdout, nil, _IOLBF, 0)
  let captures = URL(filePath: CommandLine.arguments[1])
  let checkedURL = captures.appending(path: ".words.txt")
  let reviewURL = captures.appending(path: "review.txt")
  var checked = Set(((try? String(contentsOf: checkedURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
  var review = (try? String(contentsOf: reviewURL, encoding: .utf8)) ?? ""

  let pngs = (try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil))
    + ((try? FileManager.default.contentsOfDirectory(at: captures.appending(path: "unlabeled"), includingPropertiesForKeys: nil)) ?? [])
  for url in pngs.filter({ $0.pathExtension == "png" }).sorted(by: { $0.path < $1.path }) {
    let name = String(url.deletingPathExtension().path.dropFirst(captures.path.count + 1))
    guard !checked.contains(name),
      let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
    else { continue }
    let request = VNRecognizeTextRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence > 0.5 }
      .map(\.string).filter { line in
        line.split(separator: " ").filter { $0.filter(\.isLetter).count >= 2 }.count >= 3
      }
    if !lines.isEmpty {
      review += name + "\t" + lines.joined(separator: " | ") + "\n"
      print("flagged", name, lines)
    }
    checked.insert(name)
  }
  try checked.sorted().joined(separator: "\n").write(to: checkedURL, atomically: true, encoding: .utf8)
  try review.write(to: reviewURL, atomically: true, encoding: .utf8)
#endif
