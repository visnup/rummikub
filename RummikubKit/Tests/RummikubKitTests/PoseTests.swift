import CoreGraphics
import Testing
import simd

@testable import RummikubKit

let intrinsics = simd_float3x3(columns: ([1000, 0, 0], [0, 1000, 0], [960, 540, 1]))

@Test func footprintLookingDown() {
  // Half a metre above the table, looking straight down.
  var transform = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
  transform.columns.3 = [0, 0.5, 0, 1]
  let pose = Pose(intrinsics: intrinsics, resolution: CGSize(width: 1920, height: 1080), transform: transform,
    plane: matrix_identity_float4x4)
  let size = pose.footprint(CGRect(x: 540 - 26, y: 960 - 35, width: 52, height: 70))!
  #expect(abs(size.x - 0.026) < 1e-4)
  #expect(abs(size.y - 0.035) < 1e-4)
}

@Test func standingNeverMeetsTheTable() {
  // Level with the table, 10 cm above it: the lower half of the image meets it, the upper half never does.
  // Held upright, the captured image's x runs down the screen.
  var transform = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
  transform.columns.3 = [0, 0.1, 0, 1]
  let pose = Pose(intrinsics: intrinsics, resolution: CGSize(width: 1920, height: 1080), transform: transform,
    plane: matrix_identity_float4x4)
  #expect(pose.ground(CGPoint(x: 540, y: 1500)) != nil)
  #expect(pose.ground(CGPoint(x: 540, y: 400)) == nil)
  #expect(pose.footprint(CGRect(x: 500, y: 900, width: 50, height: 700))?.y == .infinity)
}
