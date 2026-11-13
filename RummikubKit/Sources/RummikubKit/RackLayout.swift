import CoreGraphics

extension Scene {
  /// The rack as up to three even rows, as its tiles sit. Rows go along the rack's tilt, the median slope from each
  /// tile to its neighbor on the right, and split at the two widest gaps over .3 of a tile between top edges, which a
  /// nearer row never hides; World's measured depths can't, scattering ±15 mm with rows 20–30 mm apart. Along a row,
  /// each tile goes where `World` measured it, in tile pitches, unsnapped, since rows can sit half a slot apart
  /// (#327–331's 6 straddles the 8 and 13 above it); neighbors there were 26–28 mm apart. Tiles placed nowhere, kept
  /// from a scan before, follow the last row.
  /// Each tile in `rack`'s order, so a play's rack indices still name it.
  public static func laid(_ rack: [Detection]) -> [Detection] {
    let placed = rack.indices.filter { !rack[$0].frame.isNull }
    var out = rack
    for (i, d) in zip(placed, laid(placed: placed.map { rack[$0] })) { out[i] = d }
    let h = placed.map { out[$0].frame.height }.max() ?? 48
    var last = placed.map { out[$0].frame }.max { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
      ?? CGRect(x: -h * 0.78, y: 0, width: 0, height: h)
    for i in rack.indices where rack[i].frame.isNull {
      last = CGRect(x: last.minX + h * 0.78, y: last.minY, width: h * 0.72, height: h)
      out[i] = Detection(tile: rack[i].tile, frame: last)
    }
    return out
  }

  private static func laid(placed rack: [Detection]) -> [Detection] {
    func median(_ values: [CGFloat]) -> CGFloat? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
    guard let h = median(rack.map(\.frame.height)), let w = median(rack.map(\.frame.width)) else { return [] }
    let top = rack.map { CGPoint(x: $0.frame.midX, y: $0.frame.minY) }
    let slope = median(top.compactMap { p in
      top.filter { ($0.x - p.x) > w * 0.6 && ($0.x - p.x) < w * 1.5 && abs($0.y - p.y) < h * 0.4 }
        .min { $0.x < $1.x }.map { ($0.y - p.y) / ($0.x - p.x) }
    }) ?? 0
    let angle = atan(slope)
    let across = top.map { $0.y * cos(angle) - $0.x * sin(angle) }
    let order = rack.indices.sorted { across[$0] < across[$1] }
    let cuts = zip(order, order.dropFirst()).enumerated().map { ($0.offset + 1, across[$0.element.1] - across[$0.element.0]) }
      .sorted { $0.1 > $1.1 }.prefix(2).filter { $0.1 > h * 0.3 }.map(\.0).sorted()
    let measured = rack.map { CGFloat($0.along ?? 0) }
    let rows = zip([0] + cuts, cuts + [order.count]).map { row in order[row.0..<row.1].sorted { measured[$0] < measured[$1] } }
    let pitch = median(rows.flatMap { row in
      zip(row, row.dropFirst()).map { measured[$1] - measured[$0] }.filter { $0 > 0.02 && $0 < 0.035 }
    }) ?? 0.027
    let slots = measured.map { ($0 - measured.min()!) / pitch }
    var laid = rack
    for (r, row) in rows.enumerated() {
      var last: CGFloat = -1
      for i in row {
        let slot = max(slots[i], last + 1)
        last = slot
        laid[i] = Detection(tile: rack[i].tile, frame: CGRect(x: slot * h * 0.78, y: CGFloat(r) * h * 1.1,
          width: h * 0.72, height: h))
      }
    }
    return laid
  }
}
