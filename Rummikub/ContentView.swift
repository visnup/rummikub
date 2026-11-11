import CoreMotion
import ImageIO
import RummikubKit
import SwiftUI

struct ContentView: View {
  @State private var game = Game()
  @State private var camera = Camera()
  @State private var live = false
  @State private var motion = CMMotionManager()
  @State private var saved = 0
  @State private var justSaved = false
  @State private var tab = 0
  @State private var pressing = false
  @State private var topInset: CGFloat = 0
  @State private var editingNotes = false
  @State private var zoom = 1.0
  @State private var unsent: Int?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    // Tab content is opaque, so each tab draws the camera behind itself; only the selected one, since a session
    // shows in one preview layer at a time.
    // Tapping Capture again takes one, where the thumb already is.
    TabView(selection: Binding(get: { tab }, set: { if $0 == 0 && tab == 0 && live && !justSaved { shoot() }; tab = $0 })) {
      Tab("Capture", systemImage: justSaved ? "checkmark" : "camera", value: 0) {
        // Holding a finger on the camera hides everything drawn over it to check the framing; lifting it captures.
        Color.clear
          .background {
            if tab == 0 {
              preview.contentShape(.rect).gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { _ in pressing = true }
                  .onEnded { _ in
                    pressing = false
                    if tab == 0 && live && !justSaved { shoot() }
                  })
            }
          }
          .toolbarVisibility(pressing ? .hidden : .visible, for: .tabBar)
          .safeAreaBar(edge: .top) {
            HStack {
              if let tilt = game.tilt { Text("\(Int(tilt))°") }
              if let unsent {
                if unsent > 0 { Label("\(unsent)", systemImage: "arrow.up.circle") } else { Image(systemName: "checkmark.circle") }
              }
              if game.loading {
                TimelineView(.animation) { context in
                  ProgressView(value: min(context.date.timeIntervalSince(game.loadStart) / game.loadEstimate, 0.95))
                    .frame(width: 40)
                }
                Text("Loading models")
              } else {
                Text("\(Int(game.readTime / .milliseconds(1))) / \(Int(game.findTime / .milliseconds(1))) ms")
              }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect()
            // The Duo has no top safe area (its status bar is at the side), so the pill needs its own margin.
            .padding(.top, topInset == 0 ? 8 : 0)
            .opacity(pressing ? 0 : 1)
          }
          .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
          .safeAreaBar(edge: .bottom) {
            if live {
              lenses.padding(.bottom, 8).opacity(pressing ? 0 : 1)
            }
          }
      }
      Tab("Solver", systemImage: "square.grid.3x3.fill", value: 1) {
        panel(over: board) { solver }
          .safeAreaBar(edge: .top) {
            if !game.onBoard {
              HStack {
                looking.fixedSize().padding(4).glassEffect()
                if live { lenses }
              }
              .padding(.top, topInset == 0 ? 8 : 0)
            }
          }
          .background { if tab == 1 && !game.onBoard { preview } }
      }
    }
    // The system's place for a row of controls: above the tab bar, or level with it where the tab bar is at the side.
    .tabViewBottomAccessory(isEnabled: tab == 0 && !pressing) { capture }
    .sensoryFeedback(.success, trigger: saved)
    .onChange(of: scenePhase) { if scenePhase == .active { send() } }
    // The camera runs only while something needs it: the Capture tab, or a part of the Solver's being scanned.
    .onChange(of: tab == 0 || !game.onBoard) { if live { camera.run(tab == 0 || !game.onBoard) } }
    .task(id: saved) {
      try? await Task.sleep(for: .seconds(1.5))
      justSaved = false
    }
    .task {
      send()
      live = await camera.start()
      if live {
        zoom = camera.zooms[0]
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
          guard let gravity = data?.gravity else { return }
          // The back camera looks along the device's -z.
          MainActor.assumeIsolated {
            game.gravity = [gravity.x, gravity.y, gravity.z]
            game.tilt = asin(max(-1, min(1, -gravity.z))) * 180 / .pi
          }
        }
        for await frame in camera.frames { await game.see(frame) }
      } else {
        // No camera, as in the simulator: read a photo of whichever the picker says, as often as a camera would.
        while !Task.isCancelled {
          if tab == 0 || !game.onBoard, let image = Demo.photos[game.looking] { await game.see(image) }
          try? await Task.sleep(for: .seconds(0.2))
        }
      }
    }
  }

  /// The Solver's controls, too tall for the tab bar's accessory, in a bar above the tab bar, with the scene's
  /// margins and corners concentric with the display's.
  func panel(over base: some View, @ViewBuilder _ content: () -> some View) -> some View {
    base.safeAreaBar(edge: .bottom) {
      VStack(spacing: 12, content: content)
        .padding()
        .glassEffect(in: .rect(corners: .concentric(minimum: .fixed(24)), isUniform: true))
        .scenePadding(.horizontal)
    }
  }

  var board: some View {
    ZStack {
      if game.onBoard {
        Board(game: game) { part in
          game.rescan(part)
          game.pick(part)
        }
      } else {
        Color.clear
      }
    }
  }

  var preview: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack {
        if live {
          CameraPreview(session: camera.session)
        } else if let frame = game.frame {
          Image(decorative: frame, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        if let frame = game.frame, !pressing {
          Overlay(
            boxes: game.boxes, detections: tab == 1 ? game.settled : game.detections, marks: game.marks,
            fit: Fit(image: CGSize(width: frame.width, height: frame.height), view: size))
        }
      }
    }
    .ignoresSafeArea()
  }

  var lenses: some View {
    HStack(spacing: 4) {
      ForEach(camera.zooms, id: \.self) { z in
        Button(z == 0.5 ? ".5×" : "\(Int(z))×") {
          zoom = z
          camera.zoom(to: z)
        }
        .font(.caption.bold().monospacedDigit())
        .foregroundStyle(zoom == z ? .yellow : .primary)
        .frame(width: 36, height: 36)
      }
    }
    .padding(4)
    .glassEffect()
  }

  var looking: some View {
    Picker("Looking at", selection: Binding(get: { game.looking }, set: { game.pick($0) })) {
      ForEach(Game.Looking.allCases, id: \.self) { Text($0.rawValue.capitalized) }
    }
    .pickerStyle(.segmented)
  }

  /// Pushes captures to the Mac; one already under way keeps the count.
  func send() {
    Task { if let left = await Sync.push() { unsent = left } }
  }

  func shoot() {
    game.capture(camera: camera.settings)
    saved += 1
    justSaved = true
    send()
  }

  var capture: some View {
    HStack {
      looking.fixedSize()
      Menu {
        Picker("Layout", selection: $game.layout) {
          ForEach(Game.Layout.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icon) }
        }
      } label: {
        Label(game.layout.rawValue, systemImage: game.layout.icon).labelStyle(.iconOnly)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(.rect)
      }
      // The accessory stays behind the keyboard, so notes are typed in an alert, which rises above it.
      Button { editingNotes = true } label: {
        Text(game.notes.isEmpty ? "Notes" : game.notes)
          .foregroundStyle(game.notes.isEmpty ? .secondary : .primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption)
      .alert("Notes", isPresented: $editingNotes) {
        TextField("Tags", text: $game.notes)
        Button("Done") {}
      }
    }
    .padding(.horizontal)
  }

  @ViewBuilder var solver: some View {
    if let play = game.play, let step = game.step, play.steps.indices.contains(step) {
      let group = play.group(at: step), groups = play.groups
      let n = groups.lastIndex { $0 <= step } ?? 0
      HStack(alignment: .firstTextBaseline) {
        Text("\(n + 1) of \(groups.count)").font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
        Text("\(numbers(group.map { play.steps[$0].tile })) from \(source(play.steps[step].from))").font(.headline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Button("Back") { game.step = groups[n - 1] }.disabled(n == 0)
        Button("Cancel") { game.step = nil }
        if group.upperBound == play.steps.count {
          Button("Finish") { Task { await game.finish() } }.buttonStyle(.borderedProminent)
        } else {
          Button("Next") { game.step = group.upperBound }
        }
      }
      .buttonStyle(.bordered)
    } else {
      if !game.onBoard {
        HStack {
          chip(.table, count: game.scene.tableTiles.joined().count)
          chip(.rack, count: game.scene.rack.count)
        }
        VStack(alignment: .leading, spacing: 4) {
          game.scene.tableTiles.enumerated().reduce(Text("")) { text, meld in
            Text("\(text)\(meld.offset == 0 ? "" : "  ·  ")\(numbers(meld.element))")
          }
          numbers(game.scene.rackTiles)
        }
        .font(.callout.bold().monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      let bad = game.scene.tableTiles.filter { !isMeld($0) }
      if game.onBoard, game.plays.isEmpty, !bad.isEmpty {
        let melds = bad.enumerated().reduce(Text("")) { text, meld in
          Text("\(text)\(meld.offset == 0 ? "" : " · ")\(numbers(meld.element))")
        }
        Text("\(melds) isn't a meld. Tap the table to scan it again.").font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(Array(game.plays.enumerated()), id: \.offset) { i, play in
        Button {
          game.choice = i
          game.step = play.steps.isEmpty ? nil : 0
        } label: {
          Text(play.placed == 0 ? "Draw a tile" : "Place \(play.placed), move \(play.moved)")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(play.placed == 0)
      }
    }
  }

  /// Tiles as their numbers in their colors, black as the text color so it shows on dark glass.
  func numbers(_ tiles: [Tile]) -> Text {
    tiles.enumerated().reduce(Text("")) { text, tile in
      let number = Text(tile.element.face)
        .foregroundStyle(tile.element.color == .black ? .primary : Overlay.color(tile.element))
      return Text("\(text)\(tile.offset == 0 ? "" : " ")\(number)")
    }
  }

  /// A part's state: scanning, locked, or locked but reading differently; tapping scans it again.
  func chip(_ part: Game.Looking, count: Int) -> some View {
    Button {
      game.rescan(part)
    } label: {
      HStack(spacing: 6) {
        if !game.locked.contains(part) {
          ProgressView().controlSize(.mini)
        } else if game.changed(part) {
          Image(systemName: "exclamationmark.arrow.circlepath")
        } else {
          Image(systemName: "checkmark.circle.fill")
        }
        Text("\(part.rawValue.capitalized) \(count)").monospacedDigit()
        if game.changed(part) { Text("changed?") }
      }
      .font(.caption.bold())
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(game.changed(part) ? .orange : game.locked.contains(part) ? .green : .secondary)
  }

  func source(_ source: Play.Source) -> Text {
    switch source {
    case .rack: Text("your rack")
    case .table(let meld, _):
      game.scene.table.indices.contains(meld) ? numbers(game.scene.tableTiles[meld]) : Text("the table")
    }
  }
}

extension Game.Layout {
  var icon: String {
    switch self {
    case .read: "text.viewfinder"
    case .fullSet: "rectangle.grid.3x2.fill"
    case .empty: "square.dashed"
    }
  }
}

/// Maps image pixels to the view, which shows the image scaled to fill it.
struct Fit {
  let scale: CGFloat
  let offset: CGPoint

  init(image: CGSize, view: CGSize) {
    scale = max(view.width / image.width, view.height / image.height)
    offset = CGPoint(x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2)
  }

  /// `rect` scaled to fit inside `view` and centered.
  init(_ rect: CGRect, in view: CGSize) {
    scale = min(view.width / rect.width, view.height / rect.height)
    offset = CGPoint(
      x: (view.width - rect.width * scale) / 2 - rect.minX * scale,
      y: (view.height - rect.height * scale) / 2 - rect.minY * scale)
  }

  func callAsFunction(_ rect: CGRect) -> CGRect {
    CGRect(
      x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y, width: rect.width * scale,
      height: rect.height * scale)
  }

  func callAsFunction(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
  }
}

struct Overlay: View {
  let boxes: [CGRect]
  let detections: [Detection]
  let marks: [Mark]
  let fit: Fit

  var body: some View {
    Canvas { context, _ in
      for box in boxes {
        context.stroke(
          Path(roundedRect: fit(box), cornerRadius: 4), with: .color(.cyan.opacity(0.6)),
          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      }
      for detection in detections {
        let rect = fit(detection.frame)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.4)))
        let label = context.resolve(
          Text(detection.tile.face).font(.system(size: max(12, rect.width * 0.35), weight: .bold))
            .foregroundStyle(Self.color(detection.tile)))
        let size = label.measure(in: rect.size)
        let chip = CGRect(x: rect.midX - size.width / 2 - 4, y: rect.minY - size.height - 4, width: size.width + 8,
          height: size.height + 2)
        context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.white.opacity(0.85)))
        context.draw(label, in: chip.insetBy(dx: 4, dy: 1))
      }
      Self.draw(marks, in: &context, fit: fit)
    }
    .allowsHitTesting(false)
  }

  static func draw(_ marks: [Mark], in context: inout GraphicsContext, fit: Fit) {
    for mark in marks {
      switch mark {
      case .source(let rect):
        context.stroke(Path(roundedRect: fit(rect).insetBy(dx: -4, dy: -4), cornerRadius: 6), with: .color(.yellow), lineWidth: 4)
      case .target(let rect, let tile):
        let rect = fit(rect)
        context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.white.opacity(0.7)))
        context.stroke(
          Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: 6), with: .color(.yellow),
          style: StrokeStyle(lineWidth: 4, dash: [8, 5]))
        context.draw(
          Text(tile.face).font(.system(size: rect.height * 0.4, weight: .bold))
            .foregroundStyle(Self.color(tile)),
          at: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.4))
      case .arrow(let from, let to):
        let from = fit(from), to = fit(to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        for side in [-1.0, 1.0] {
          path.move(to: to)
          path.addLine(to: CGPoint(x: to.x - 18 * cos(angle + side * 0.5), y: to.y - 18 * sin(angle + side * 0.5)))
        }
        context.stroke(path, with: .color(.yellow), lineWidth: 4)
      case .caption:
        break
      }
    }
  }

  static func color(_ tile: Tile) -> Color {
    switch tile.color {
    case .black: .black
    case .blue: .blue
    case .orange: .orange
    case .red, nil: .red
    }
  }
}

/// Photos from `Demo/`, read straight off the Mac, which the simulator can see.
enum Demo {
  static let photos: [Game.Looking: CGImage] = [.table: "2026-11-06T155531Z", .rack: "2026-11-06T155556Z"]
    .compactMapValues { name in
      let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Demo/\(name).png")
      return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
