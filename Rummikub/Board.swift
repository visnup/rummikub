import RummikubKit
import SwiftUI

/// The table and rack as last read, each laid out as it sat in its frame, with the step being shown drawn on them,
/// and the controls between them. The table pans and zooms. Tapping either scans it again.
struct Board<Controls: View>: View {
  let game: Game
  let scan: (Game.Area) -> Void
  /// A long press on either part, for when it's gone wrong.
  let report: () -> Void
  @ViewBuilder let controls: Controls
  @State private var zoom: CGFloat = 1
  @State private var pan = CGSize.zero
  @GestureState private var pinching: (scale: CGFloat, at: CGPoint)?
  @GestureState private var dragging = CGSize.zero
  @State private var size = CGSize.zero

  /// The zoom and pan after a pinch by `scale` about `at`, which stays put.
  func pinched(_ scale: CGFloat, at: CGPoint) -> (zoom: CGFloat, pan: CGSize) {
    let scale = max(scale, 1 / zoom)
    return (zoom * scale, CGSize(width: scale * pan.width + (1 - scale) * (at.x - size.width / 2),
      height: scale * pan.height + (1 - scale) * (at.y - size.height / 2)))
  }

  var body: some View {
    let rack = Scene.laid(game.scene.rack)
    let rows = Set(rack.map(\.frame.minY)).count
    let (zoom, pan) = pinching.map { pinched($0.scale, at: $0.at) } ?? (zoom, pan)
    VStack(spacing: 12) {
      part(.table, tiles: Array(game.scene.table.joined()), marks: fromRack ? marks.filter(\.isTarget) : marks,
        zoom: zoom, pan: CGSize(width: pan.width + dragging.width, height: pan.height + dragging.height))
        .clipped()
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .gesture(
          MagnifyGesture()
            .updating($pinching) { value, state, _ in state = (value.magnification, value.startLocation) }
            .onEnded { (self.zoom, self.pan) = pinched($0.magnification, at: $0.startLocation) }
            .simultaneously(with: DragGesture()
              .updating($dragging) { value, state, _ in state = value.translation }
              .onEnded { self.pan = CGSize(width: self.pan.width + $0.translation.width,
                height: self.pan.height + $0.translation.height) }))
      controls
    }
    .padding()
    .bottomBar {
      part(.rack, tiles: rack, marks: fromRack ? rackMarks : [])
        .frame(height: CGFloat(max(rows, 1)) * 36 + 48)
        .background(.fill.tertiary, in: .rect(corners: .concentric(minimum: .fixed(16)), isUniform: true))
        .scenePadding(.horizontal)
    }
  }

  /// The current step's marks in the table's pixels, but for a tile from the rack, whose source is in the rack's.
  var marks: [Mark] {
    guard let play = game.play, let step = game.step, play.steps.indices.contains(step) else { return [] }
    let marks = play.group(at: step).flatMap { play.marks(in: game.scene, step: $0, within: game.tableBounds) }
    return fromRack ? marks.filter { if case .arrow = $0 { false } else { true } } : marks
  }

  /// The tiles to pick up from the rack, where `Scene.laid` draws them.
  var rackMarks: [Mark] {
    guard let play = game.play, let step = game.step else { return [] }
    let laid = Scene.laid(game.scene.rack)
    return play.group(at: step).compactMap {
      guard case .rack(let i) = play.steps[$0].from, laid.indices.contains(i) else { return nil }
      return .source(laid[i].frame)
    }
  }

  var fromRack: Bool {
    guard let play = game.play, let step = game.step, play.steps.indices.contains(step),
      case .rack = play.steps[step].from
    else { return false }
    return true
  }

  func part(_ part: Game.Area, tiles: [Detection], marks: [Mark], zoom: CGFloat = 1, pan: CGSize = .zero)
    -> some View
  {
    Canvas { context, size in
      let rects = tiles.map(\.frame) + marks.compactMap(\.rect)
      guard let first = rects.first else { return }
      context.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
      context.scaleBy(x: zoom, y: zoom)
      context.translateBy(x: -size.width / 2, y: -size.height / 2)
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
    // Below its label: the rack fills its box, where the table has room above its tiles.
    .padding(.top, part == .rack ? 24 : 0)
    .overlay(alignment: .topLeading) {
      Label("\(part.rawValue.capitalized) \(tiles.count)", systemImage: "checkmark.circle.fill")
        .font(.caption.bold().monospacedDigit()).foregroundStyle(.green).padding(10)
    }
    .overlay { if tiles.isEmpty { Text("Tap to scan").foregroundStyle(.secondary) } }
    .contentShape(.rect)
    .onLongPressGesture { report() }
    .onTapGesture { scan(part) }
  }
}

/// The system's place for a bar, above the tab bar. Where the tab bar is at the side, as on the iPhone Duo, that
/// leaves the home indicator's inset below it, so the bar drops to 24 pt off the bottom, level with the tab bar.
struct BottomBar<Bar: View>: ViewModifier {
  let bar: Bar
  @State private var insets = EdgeInsets()

  func body(content: Content) -> some View {
    content
      .safeAreaBar(edge: .bottom) { bar.padding(.bottom, insets.trailing > 0 ? -max(insets.bottom - 24, 0) : 0) }
      .onGeometryChange(for: EdgeInsets.self, of: \.safeAreaInsets) { insets = $0 }
  }
}

extension View {
  func bottomBar(@ViewBuilder _ bar: () -> some View) -> some View { modifier(BottomBar(bar: bar())) }
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
