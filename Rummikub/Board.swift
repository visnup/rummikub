import RummikubKit
import SwiftUI

/// The table and rack as last read, each laid out as it sat in its frame, with the step being shown drawn on them.
/// Tapping either scans it again.
struct Board: View {
  let game: Game
  let scan: (Game.Looking) -> Void

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 12) {
        part(.table, tiles: Array(game.scene.table.joined()), marks: fromRack ? marks.filter(\.isTarget) : marks)
          .frame(height: (geometry.size.height - 12) * 0.65)
        part(.rack, tiles: Self.rows(game.scene.rack), marks: fromRack ? rackMarks : [])
      }
    }
    .padding()
  }

  /// The current step's marks in the table's pixels, but for a tile from the rack, whose source is in the rack's.
  var marks: [Mark] {
    guard let play = game.play, let step = game.step, play.steps.indices.contains(step) else { return [] }
    let marks = play.group(at: step).flatMap { play.marks(in: game.scene, step: $0, within: game.tableBounds) }
    return fromRack ? marks.filter { if case .arrow = $0 { false } else { true } } : marks
  }

  /// The tiles to pick up from the rack, where `rows` draws them.
  var rackMarks: [Mark] {
    guard let play = game.play, let step = game.step else { return [] }
    let laid = Self.rows(game.scene.rack)
    return play.group(at: step).compactMap {
      guard case .rack(let i) = play.steps[$0].from, laid.indices.contains(i) else { return nil }
      return .source(laid[i].frame)
    }
  }

  /// The rack as even rows, in the order its tiles sit, since its frames overlap in perspective: rows split where a
  /// tile sits over half a tile higher than the last.
  static func rows(_ rack: [Detection]) -> [Detection] {
    let heights = rack.map(\.frame.height).sorted()
    guard !heights.isEmpty else { return [] }
    let h = heights[heights.count / 2]
    var rows = [[Int]]()
    for i in rack.indices.sorted(by: { rack[$0].frame.midY < rack[$1].frame.midY }) {
      if let last = rows.last?.last, rack[i].frame.midY - rack[last].frame.midY < h / 2 {
        rows[rows.count - 1].append(i)
      } else {
        rows.append([i])
      }
    }
    var laid = rack
    for (r, row) in rows.enumerated() {
      for (c, i) in row.sorted(by: { rack[$0].frame.midX < rack[$1].frame.midX }).enumerated() {
        laid[i] = Detection(tile: rack[i].tile, frame: CGRect(x: CGFloat(c) * h * 0.78, y: CGFloat(r) * h * 1.1,
          width: h * 0.72, height: h))
      }
    }
    return laid
  }

  var fromRack: Bool {
    guard let play = game.play, let step = game.step, play.steps.indices.contains(step),
      case .rack = play.steps[step].from
    else { return false }
    return true
  }

  func part(_ part: Game.Looking, tiles: [Detection], marks: [Mark]) -> some View {
    Canvas { context, size in
      let rects = tiles.map(\.frame) + marks.compactMap(\.rect)
      guard let first = rects.first else { return }
      let margin = (rects.map(\.height).max() ?? 0) * 0.3
      let fit = Fit(rects.reduce(first) { $0.union($1) }.insetBy(dx: -margin, dy: -margin), in: size)
      let bad = Set(game.scene.table.filter { !isMeld($0.map(\.tile)) }.joined())
      for tile in tiles {
        let rect = fit(tile.frame).insetBy(dx: 1, dy: 1)
        let face = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.12)
        context.fill(face, with: .color(Color(white: 0.97)))
        if part == .table && bad.contains(tile) {
          context.stroke(face, with: .color(.red), lineWidth: 3)
        } else {
          context.stroke(face, with: .color(.black.opacity(0.2)))
        }
        context.draw(
          Text(tile.tile.face)
            .font(.system(size: min(rect.width, rect.height) * 0.55, weight: .bold))
            .foregroundStyle(Overlay.color(tile.tile)),
          at: CGPoint(x: rect.midX, y: rect.midY))
      }
      Overlay.draw(marks, in: &context, fit: fit)
    }
    .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    .overlay(alignment: .topLeading) {
      Label("\(part.rawValue.capitalized) \(tiles.count)", systemImage: "checkmark.circle.fill")
        .font(.caption.bold().monospacedDigit()).foregroundStyle(.green).padding(10)
    }
    .overlay { if tiles.isEmpty { Text("Tap to scan").foregroundStyle(.secondary) } }
    .contentShape(.rect)
    .onTapGesture { scan(part) }
  }
}

extension Mark {
  var isTarget: Bool { if case .target = self { true } else { false } }

  var rect: CGRect? {
    switch self {
    case .source(let rect), .target(let rect, _): rect
    default: nil
    }
  }
}
