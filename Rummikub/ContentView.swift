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

  var body: some View {
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
        if let frame = game.frame {
          Overlay(
            detections: game.detections, marks: game.marks,
            fit: Fit(image: CGSize(width: frame.width, height: frame.height), view: size))
        }
      }
    }
    .ignoresSafeArea()
    .overlay(alignment: .bottom) { controls }
    .task {
      live = await camera.start()
      if live {
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
          if let image = Demo.photos[game.looking] { await game.see(image) }
          try? await Task.sleep(for: .seconds(0.3))
        }
      }
    }
  }

  var controls: some View {
    VStack(spacing: 12) {
      if let play = game.play, let step = game.step {
        let current = play.steps[step]
        Text("Step \(step + 1) of \(play.steps.count): \(current.tile.description) from \(source(current.from))")
          .font(.headline)
        HStack {
          Button("Back") { game.step = step - 1 }.disabled(step == 0)
          Button("Done") { game.step = nil }
          Button("Next") { game.step = step + 1 }.disabled(step == play.steps.count - 1)
        }
        .buttonStyle(.bordered)
      } else {
        HStack {
          Picker("Looking at", selection: $game.looking) {
            ForEach(Game.Looking.allCases, id: \.self) { Text($0.rawValue.capitalized) }
          }
          .pickerStyle(.segmented)
          if live {
            if let tilt = game.tilt { Text("\(Int(tilt))°").font(.caption.monospacedDigit()) }
            if saved > 0 { Text("\(saved) saved").font(.caption) }
            Button("Capture", systemImage: justSaved ? "checkmark" : "camera.shutter.button") {
              game.capture(camera: camera.settings)
              saved += 1
              justSaved = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(justSaved)
            .sensoryFeedback(.success, trigger: saved)
            .task(id: saved) {
              try? await Task.sleep(for: .seconds(1.5))
              justSaved = false
            }
          }
        }
        if live {
          HStack {
            Picker("Layout", selection: $game.layout) {
              ForEach(Game.Layout.allCases, id: \.self) { Text($0.rawValue) }
            }
            TextField("Light, surface, clutter", text: $game.notes)
              .textFieldStyle(.roundedBorder)
              .font(.caption)
            Text("\(Int(game.readTime / .milliseconds(1))) ms").font(.caption.monospacedDigit())
          }
        }
        VStack(alignment: .leading) {
          Text("Table: " + game.scene.table.map { $0.map(\.tile.description).joined(separator: " ") }
            .joined(separator: " · "))
          Text("Rack: " + game.scene.rack.map(\.tile.description).joined(separator: " "))
        }
        .font(.caption.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(game.plays.indices, id: \.self) { i in
          let play = game.plays[i]
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
    .padding()
    .glassEffect(in: .rect(cornerRadius: 24))
    .padding()
  }

  func source(_ source: Play.Source) -> String {
    switch source {
    case .rack: "your rack"
    case .table(let meld, _): game.scene.table[meld].map(\.tile.description).joined(separator: " ")
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
  let detections: [Detection]
  let marks: [Mark]
  let fit: Fit

  var body: some View {
    Canvas { context, _ in
      for detection in detections {
        let rect = fit(detection.frame)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.4)))
        let label = context.resolve(
          Text(detection.tile.description).font(.system(size: max(12, rect.width * 0.35), weight: .bold))
            .foregroundStyle(color(detection.tile)))
        let size = label.measure(in: rect.size)
        let chip = CGRect(x: rect.midX - size.width / 2 - 4, y: rect.minY - size.height - 4, width: size.width + 8,
          height: size.height + 2)
        context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.white.opacity(0.85)))
        context.draw(label, in: chip.insetBy(dx: 4, dy: 1))
      }
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
            Text(tile == .joker ? "☺" : "\(tile.value!)").font(.system(size: rect.height * 0.4, weight: .bold))
              .foregroundStyle(color(tile)),
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
        case .caption, .label:
          break
        }
      }
    }
    .allowsHitTesting(false)
  }

  func color(_ tile: Tile) -> Color {
    switch tile.color {
    case .black: .black
    case .blue: .blue
    case .orange: .orange
    case .red, nil: .red
    }
  }
}

/// Photos from the test fixtures, read straight off the Mac, which the simulator can see.
enum Demo {
  static let photos: [Game.Looking: CGImage] = [.table: "2026-11-06T155531Z", .rack: "2026-11-06T155556Z"]
    .compactMapValues { name in
      let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../RummikubKit/Tests/RummikubKitTests/Fixtures/\(name).png")
      return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
