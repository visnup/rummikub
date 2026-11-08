import Foundation

/// Pushes captures to the labeler on the Mac (`Labeler/server.py`) and deletes each file once the Mac has it, so
/// what's left in Documents is what hasn't gone yet. That waits for the next capture, launch or return to the app.
enum Sync {
  /// Resolves at home and over the phone's VPN.
  static let labeler = URL(string: "http://box.localdomain:8765/api/capture/")!
  private static var pushing = false

  /// Sends every capture file, photos last, so the labeler has a capture's notes when its photo arrives. Stops at the
  /// first failure, and returns how many captures are still to send.
  @discardableResult static func push() async -> Int? {
    // Two pushes at once send the same files twice and each slows the other.
    guard !pushing else { return nil }
    pushing = true
    defer { pushing = false }
    let documents = URL.documentsDirectory
    // From before files were deleted once sent.
    try? FileManager.default.removeItem(at: documents.appending(path: ".sent"))
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? [])
      .filter { ["png", "txt", "json"].contains(($0 as NSString).pathExtension) }
      .sorted { ($0.hasSuffix(".png") ? 1 : 0, $0) < ($1.hasSuffix(".png") ? 1 : 0, $1) }
    var left = files.filter { $0.hasSuffix(".png") }.count
    for file in files {
      let url = documents.appending(path: file)
      // A photo takes several seconds while the Mac is busy pre-labeling; 10 s cut some off.
      var request = URLRequest(url: labeler.appending(path: file), timeoutInterval: 60)
      request.httpMethod = "PUT"
      // The labeler answers 200 once it has the file, saved now or before.
      guard let data = try? Data(contentsOf: url),
        let (_, response) = try? await URLSession.shared.upload(for: request, from: data),
        (response as? HTTPURLResponse)?.statusCode == 200
      else { return left }
      try? FileManager.default.removeItem(at: url)
      if file.hasSuffix(".png") { left -= 1 }
    }
    return 0
  }
}
