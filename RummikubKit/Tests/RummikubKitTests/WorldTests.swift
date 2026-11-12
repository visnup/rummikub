import CoreGraphics
import Testing
import simd

@testable import RummikubKit

/// Looking down from 40 cm up, at 45° from 40 cm back, `x` metres to the right.
private func pose(_ x: Float, back: Float = 0.4) -> Pose {
  var transform = simd_float4x4(simd_quatf(angle: -atan(0.4 / back), axis: [1, 0, 0]) * simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
  transform.columns.3 = [x, 0.4, back, 1]
  return Pose(intrinsics: intrinsics, resolution: CGSize(width: 1920, height: 1080), transform: transform,
    plane: matrix_identity_float4x4)
}

/// A tile lying on the table with its near edge's middle at `foot`, as `pose` boxes it.
private func seen(_ tile: String, at foot: SIMD3<Float>, from pose: Pose, width: Float = 0.03, rack: Float? = nil) -> Detection {
  let near = [foot - [width / 2, 0, 0], foot + [width / 2, 0, 0]].map { pose.project($0)! }
  let far = pose.project(foot - [0, 0, 0.04])!
  let box = CGRect(x: near[0].x, y: far.y, width: near[1].x - near[0].x, height: near[0].y - far.y)
  return Detection(tile: Tile(tile)!, frame: box, rack: rack)
}

@Test func rackTileOnALedge() {
  var world = World()
  // Its foot 3 cm above the table, seen from 45° down to 27°, where its ray meets the table 3 cm further back.
  let foot: SIMD3<Float> = [0, 0.03, 0]
  for back: Float in [0.4, 0.4, 0.5, 0.6, 0.7, 0.8, 0.8, 0.4] {
    world.add([seen("k5", at: foot, from: pose(0, back: back), rack: 0.95)], pose: pose(0, back: back))
  }
  #expect(world.places.count == 1)
  #expect(abs(world.places[0].height - 0.03) < 0.005)
}

@Test func twoOfATileByPlace() {
  var world = World()
  let a: SIMD3<Float> = [-0.05, 0, 0], b: SIMD3<Float> = [0.05, 0, 0]
  for x: Float in [0, 0.03, 0.06] {
    let p = pose(x)
    world.add([seen("r5", at: a, from: p), seen("r5", at: b, from: p)], pose: p)
  }
  #expect(world.places.count == 2)
  #expect(world.places.allSatisfy { $0.sure && $0.seen == 3 && $0.tile == Tile("r5")! })
  #expect(abs(world.places[0].point.x - a.x) < 0.002 && abs(world.places[1].point.x - b.x) < 0.002)
}

@Test func votesEachPlace() {
  var world = World()
  let p = pose(0), foot: SIMD3<Float> = [0, 0, 0]
  for tile in ["k6", "k9", "k6"] { world.add([seen(tile, at: foot, from: p)], pose: p) }
  #expect(world.places.map(\.tile) == [Tile("k6")!])
}

@Test func forgetsATilePickedUp() {
  var world = World()
  let p = pose(0), here: SIMD3<Float> = [0, 0, 0], there: SIMD3<Float> = [0.06, 0, 0]
  world.add([seen("b3", at: here, from: p), seen("o7", at: there, from: p)], pose: p)
  for _ in 0..<World.forgotten { world.add([seen("o7", at: there, from: p)], pose: p) }
  #expect(world.places.map(\.tile) == [Tile("o7")!])
}

@Test func keepsWhatsCovered() {
  var world = World()
  let p = pose(0), here: SIMD3<Float> = [0, 0, 0], there: SIMD3<Float> = [0.06, 0, 0]
  world.add([seen("b3", at: here, from: p), seen("o7", at: there, from: p)], pose: p)
  // A hand over the whole image, as ARKit's segmentation marks it.
  let hand = World.Mask(width: 256, height: 192, bytes: [UInt8](repeating: 255, count: 256 * 192))
  for _ in 0..<5 { world.add([seen("o7", at: there, from: p)], pose: p, mask: hand) }
  // Another box over it, its foot nearer, as a rack tile in front.
  let behind = seen("b3", at: here, from: p).frame
  let front = Detection(tile: Tile("k1")!, frame: behind.offsetBy(dx: 0, dy: behind.height * 0.6))
  for _ in 0..<5 { world.add([seen("o7", at: there, from: p), front], pose: p) }
  #expect(world.places.contains { $0.tile == Tile("b3")! })
}

@Test func maskCoversTheUprightBox() {
  // A person over the captured image's left half, x < 960, which is the upright image's top half.
  let mask = World.Mask(width: 4, height: 2, bytes: [255, 255, 0, 0, 255, 255, 0, 0])
  let size = CGSize(width: 1920, height: 1080)
  #expect(mask.covers(CGRect(x: 100, y: 100, width: 50, height: 50), resolution: size) == 1)
  #expect(mask.covers(CGRect(x: 100, y: 1500, width: 50, height: 50), resolution: size) == 0)
}

@Test func keepsWhatsOutOfView() {
  var world = World()
  let near = pose(0), away = pose(2), foot: SIMD3<Float> = [0, 0, 0]
  world.add([seen("j", at: foot, from: near)], pose: near)
  world.add([seen("j", at: foot, from: near)], pose: near)
  for _ in 0..<5 { world.add([], pose: away) }
  #expect(world.places.count == 1)
  let box = world.detections(from: near)[0].detection.frame, truth = seen("j", at: foot, from: near).frame
  #expect(abs(box.midX - truth.midX) < 1 && abs(box.maxY - truth.maxY) < 1 && abs(box.width - truth.width) < 1)
}

@Test func levelsToTheTiles() {
  var world = World()
  // ARKit found the floor 60 cm under the table, as over dark felt in #327–331.
  var floor = matrix_identity_float4x4
  floor.columns.3.y = -0.6
  let feet: [SIMD3<Float>] = [[-0.05, 0, 0], [0, 0, 0], [0.05, 0, 0]]
  func found(_ x: Float) -> Pose {
    var p = pose(x)
    p.plane = floor
    return p
  }
  for x: Float in [0, 0.05, 0.1] {
    world.add(zip(["r1", "r2", "r3"], feet).map { seen($0, at: $1, from: pose(x), width: World.tileWidth) }, pose: found(x))
  }
  #expect(abs(world.level(found(0)).plane!.columns.3.y) < 0.001)
  #expect(world.places.count == 3)
  #expect(zip(world.places, feet).allSatisfy { distance($0.point, $1) < 0.002 })
}

@Test func meldsAlongTheTable() {
  var world = World()
  let p = pose(0), slope = SIMD3<Float>(cos(.pi / 6), 0, -sin(.pi / 6)) * 0.03
  // A run rising at 30° on the table, and a tile just behind its first, as #323's r8 behind r10.
  let run = (0..<3).map { seen("b\($0 + 4)", at: [-0.06, 0, 0] + slope * Float($0), from: p) }
  let behind = seen("k9", at: [-0.06, 0, -0.042], from: p)
  for _ in 0..<2 { world.add(run.reversed() + [behind], pose: p) }
  let melds = World.melds(world.detections(from: p)).map { $0.map(\.tile.description).joined(separator: " ") }
  #expect(Set(melds) == ["b4 b5 b6", "k9"])
}
