import CoreGraphics
import Testing
import simd

@testable import RummikubKit

/// Looking down at 45° from 40 cm, `x` metres to the right.
private func pose(_ x: Float) -> Pose {
  var transform = simd_float4x4(simd_quatf(angle: -.pi / 4, axis: [1, 0, 0]) * simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
  transform.columns.3 = [x, 0.4, 0.4, 1]
  return Pose(intrinsics: intrinsics, resolution: CGSize(width: 1920, height: 1080), transform: transform,
    plane: matrix_identity_float4x4)
}

/// A tile lying on the table with its near edge's middle at `foot`, as `pose` boxes it.
private func seen(_ tile: String, at foot: SIMD3<Float>, from pose: Pose) -> Detection {
  let near = [foot - [0.015, 0, 0], foot + [0.015, 0, 0]].map { pose.project($0)! }
  let far = pose.project(foot - [0, 0, 0.04])!
  let box = CGRect(x: near[0].x, y: far.y, width: near[1].x - near[0].x, height: near[0].y - far.y)
  return Detection(tile: Tile(tile)!, frame: box)
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
