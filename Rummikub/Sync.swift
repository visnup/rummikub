import Foundation

/// Pushes captures to the labeler on the Mac (`Labeler/server.py`). Whatever doesn't get through waits for the next
/// capture or launch; `make captures` still copies them by cable.
enum Sync {
  static let labeler = URL(string: "http://box.local:8765/api/capture/")!

  /// Sends every capture file not sent yet, photos last, so the labeler has a capture's notes when its photo arrives.
  /// Stops at the first failure.
  static func push() async {
    let documents = URL.documentsDirectory
    let sentURL = documents.appending(path: ".sent")
    var sent = Set(((try? String(contentsOf: sentURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? [])
      .filter { ["png", "txt", "json"].contains(($0 as NSString).pathExtension) && !sent.contains($0) }
      .sorted { ($0.hasSuffix(".png") ? 1 : 0, $0) < ($1.hasSuffix(".png") ? 1 : 0, $1) }
    for file in files {
      var request = URLRequest(url: labeler.appending(path: file), timeoutInterval: 10)
      request.httpMethod = "PUT"
      guard let data = try? Data(contentsOf: documents.appending(path: file)),
        let (_, response) = try? await URLSession.shared.upload(for: request, from: data),
        (response as? HTTPURLResponse)?.statusCode == 200
      else { return }
      sent.insert(file)
      try? sent.sorted().joined(separator: "\n").write(to: sentURL, atomically: true, encoding: .utf8)
    }
  }
}
