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
  @AppStorage("ar") private var ar = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    // Tab content is opaque, so each tab draws the camera behind itself; only the selected one, since a session
    // shows in one preview layer at a time.
    // Tapping Capture again takes one, where the thumb already is.
    TabView(selection: Binding(get: { tab }, set: { if $0 == 0 && tab == 0 && live && !justSaved { shoot() }; tab = $0 })) {
      Tab("Capture", systemImage: game.recording != nil ? "stop.circle" : justSaved ? "checkmark" : ar ? "record.circle" : "camera", value: 0) {
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
              if ar, let frame = game.ar {
                if frame.tracking != "normal" {
                  Text(frame.tracking)
                } else if let height = frame.pose?.height {
                  // The camera above the table, and how far `World.level` lifted ARKit's plane to reach it.
                  let lift = (camera.pose?.height ?? height) - height
                  Text("table \(Int(height * 100)) cm" + (lift > 0.05 ? ", lifted \(Int(lift * 100))" : ""))
                } else {
                  Text("no table")
                }
              }
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
        NavigationStack {
          Group {
            if game.onBoard {
              Board(game: game) { part in
                game.rescan(part)
                game.pick(part)
              } report: {
                game.report(camera: camera.settings)
                saved += 1
                justSaved = true
                send()
              } controls: {
                VStack(spacing: 12) { solver }
                  .padding()
                  .glassEffect(in: .rect(cornerRadius: 24))
              }
            } else {
              panel(over: Color.clear) { solver }
            }
          }
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
          .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
              // A menu, so starting over takes a second tap to confirm.
              Menu("New game", systemImage: "arrow.counterclockwise") {
                Button("Forget this table and rack", systemImage: "arrow.counterclockwise", role: .destructive) {
                  game.newGame()
                }
              }
            }
          }
        }
      }
    }
    // The system's place for a row of controls: above the tab bar, or level with it where the tab bar is at the side.
    .tabViewBottomAccessory(isEnabled: tab == 0 && !pressing) { capture }
    .sensoryFeedback(.success, trigger: saved)
    .onChange(of: scenePhase) { if scenePhase == .active { send() } }
    // The camera runs only while something needs it: the Capture tab, or a part of the Solver's being scanned.
    .onChange(of: tab == 0 || !game.onBoard) {
      guard live else { return }
      if tab == 0 || !game.onBoard { game.restart() }
      camera.run(tab == 0 || !game.onBoard)
    }
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
        if ar { camera.use(ar: true) }
        for await frame in camera.frames { await game.see(frame.image, ar: frame.pose == nil ? nil : frame) }
      } else {
        // No camera, as in the simulator: replay an AR recording at its pace, over and over.
        while !Task.isCancelled, let first = Replay.frames.first {
          for (f, next) in zip(Replay.frames, Replay.frames.dropFirst() + [first]) where !Task.isCancelled {
            if tab == 0 || !game.onBoard {
              game.looking = f.looking
              await game.see(f.frame.image, ar: f.frame, read: f.read)
            }
            try? await Task.sleep(for: .seconds(min(max(next.time - f.time, 0.1), 1)))
          }
        }
      }
    }
  }

  /// The Solver's controls, too tall for the tab bar's accessory, in a bar above the tab bar, with the scene's
  /// margins and corners concentric with the display's.
  func panel(over base: some View, @ViewBuilder _ content: () -> some View) -> some View {
    base.bottomBar {
      VStack(spacing: 12, content: content)
        .padding()
        .glassEffect(in: .rect(corners: .concentric(minimum: .fixed(24)), isUniform: true))
        .scenePadding(.horizontal)
    }
  }

  var preview: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack {
        if live && ar {
          ARPreview(session: camera.arSession)
        } else if live {
          CameraPreview(session: camera.session)
        } else if let frame = game.frame {
          Image(decorative: frame, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        if let frame = game.frame, !pressing {
          let fit = Fit(image: CGSize(width: frame.width, height: frame.height), view: size)
          let overlay = { (fit: Fit) in
            Overlay(
              boxes: game.boxes, footprints: game.footprints, detections: tab == 1 ? game.settled : game.detections,
              marks: game.marks, fit: fit)
          }
          // With ARKit, redrawn every display frame where the camera is now, as if on the table, between reads.
          if live && ar, let then = game.ar?.pose, then.plane != nil {
            TimelineView(.animation) { _ in overlay(fit.following(then, to: camera.pose)) }
          } else {
            overlay(fit)
          }
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
          if ar {
            ar = false
            camera.use(ar: false)
          }
          camera.zoom(to: z)
        }
        .foregroundStyle(!ar && zoom == z ? .yellow : .primary)
        .frame(width: 36, height: 36)
      }
      if Camera.arSupported {
        Button("AR") {
          ar.toggle()
          camera.use(ar: ar)
          if !ar { camera.zoom(to: zoom) }
        }
        .foregroundStyle(ar ? .yellow : .primary)
        .frame(width: 36, height: 36)
      }
    }
    .font(.caption.bold().monospacedDigit())
    .padding(4)
    .glassEffect()
  }

  /// Without a pose; with one, `World` tells the rack from the table.
  @ViewBuilder var looking: some View {
    if game.ar?.pose == nil {
      Picker("Looking at", selection: Binding(get: { game.looking }, set: { game.pick($0) })) {
        ForEach(Game.Looking.allCases, id: \.self) { Text($0.rawValue.capitalized) }
      }
      .pickerStyle(.segmented)
    }
  }

  /// Pushes captures to the Mac; one already under way keeps the count.
  func send() {
    Task { if let left = await Sync.push() { unsent = left } }
  }

  /// A capture, or in AR a recording started or stopped.
  func shoot() {
    if ar && game.recording == nil {
      game.startRecording(camera: camera.settings)
    } else if ar {
      game.stopRecording()
    } else {
      game.capture(camera: camera.settings)
    }
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
      if !game.opened {
        Text("Lay down 30 to open").font(.callout).foregroundStyle(.secondary)
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
  /// The pose the image was taken from, and the camera's now: image positions move to where they show now.
  private var follow: (then: Pose, now: Pose)?

  func following(_ then: Pose, to now: Pose?) -> Fit {
    var fit = self
    fit.follow = now.map { (then, $0) }
    return fit
  }

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
    let rect = follow.flatMap { $0.then.follow(rect, to: $0.now) } ?? rect
    return CGRect(
      x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y, width: rect.width * scale,
      height: rect.height * scale)
  }

  func callAsFunction(_ point: CGPoint) -> CGPoint {
    let point = follow.flatMap { $0.then.follow(point, to: $0.now) } ?? point
    return CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
  }
}

struct Overlay: View {
  let boxes: [CGRect]
  /// Each box's size on the table, in metres, with ARKit.
  var footprints = [SIMD2<Float>?]()
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
      // In millimetres, green where it's about a tile's size, so lying on the table; "∞" never meets it.
      for (box, size) in zip(boxes, footprints) {
        guard let size else { continue }
        let rect = fit(box)
        let lying = max(size.x, size.y) < 0.06
        let text = size.y.isFinite ? "\(Int(size.x * 1000))×\(Int(size.y * 1000))" : "\(Int(size.x * 1000))×∞"
        context.draw(
          Text(text).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(lying ? .green : .orange),
          at: CGPoint(x: rect.midX, y: rect.maxY + 7))
      }
      for detection in detections {
        let rect = fit(detection.frame)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4),
          with: .color((detection.rack ?? 0) >= 0.5 ? .purple : .white), lineWidth: 2)
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

/// An AR recording in `Captures/`, read straight off the Mac, which the simulator can see: each frame's pose, person
/// mask and reads, with the last photo the recording captured by then.
enum Replay {
  static let name = "2026-11-12T14:17:55Z"
  static let frames: [(time: Double, looking: Game.Looking, frame: Frame, read: [Detection])] = {
    let captures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Captures")
    guard let recording = try? Recording(contentsOf: captures.appending(path: name + ".jsonl")) else { return [] }
    let photos = [captures, captures.appending(path: "unlabeled")].flatMap { folder in
      ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap {
        url -> (time: Double, image: CGImage)? in
        let stem = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", let time = try? Date(stem, strategy: .iso8601),
          let notes = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
          notes["recording"] as? String == name,
          let image = CGImageSourceCreateWithURL(url.deletingLastPathComponent().appending(path: stem + ".png") as CFURL, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
        else { return nil }
        return (time.timeIntervalSince1970, image)
      }
    }.sorted { $0.time < $1.time }
    guard let first = photos.first else { return [] }
    return recording.frames.map { f in
      let image = photos.last { $0.time <= f.time + 1 }?.image ?? first.image
      return (f.time, Game.Looking(rawValue: f.looking) ?? .table,
        Frame(image: image, pose: f.pose, tracking: "normal", mask: f.mask), f.detections)
    }
  }()
}
