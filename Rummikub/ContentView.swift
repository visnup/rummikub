import RummikubKit
import SwiftUI

struct ContentView: View {
  @State private var game = Game()
  @State private var camera = Camera()
  @State private var live = false

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
        for await frame in camera.frames { await game.see(frame) }
      } else {
        // No camera, as in the simulator: read a rendered table and rack, again and again like a camera would.
        let (image, _) = Render.table(Demo.table, rack: Demo.rack, width: 804, height: 1748, top: 220, bottom: 640)
        while !Task.isCancelled {
          await game.see(image, rackY: 1748 - 640 - 120)
          try? await Task.sleep(for: .seconds(1))
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
        if live {
          HStack {
            Picker("Looking at", selection: $game.looking) {
              ForEach(Game.Looking.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .pickerStyle(.segmented)
            Button("Capture", systemImage: "camera.shutter.button") { game.capture() }
              .labelStyle(.iconOnly)
              .buttonStyle(.bordered)
          }
        }
        Text("\(game.scene.table.joined().count) on the table, \(game.scene.rack.count) in your rack")
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
        context.stroke(Path(roundedRect: fit(detection.frame), cornerRadius: 4), with: .color(.white.opacity(0.4)))
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

enum Demo {
  static let table = [
    "r3 r4 r5 r6", "k1 k2 k3", "b9 b10 b11", "o12 r12 b12", "j k7 k8", "o4 o5 o6",
  ].map(Tile.parse)
  static let rack = Tile.parse("b6 k6 k4 o3 b13 o9 r9")
}
