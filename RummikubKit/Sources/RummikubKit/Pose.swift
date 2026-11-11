import CoreGraphics
import simd

/// Where ARKit says the camera was, and the table plane it found, enough to say where a point in the image lies on the
/// table. The intrinsics and resolution are for the image as captured, which turns a quarter clockwise to be upright.
public struct Pose: Sendable {
  public var intrinsics: simd_float3x3
  public var resolution: CGSize
  /// Camera to world, in metres. The camera looks along its -z.
  public var transform: simd_float4x4
  /// The table: a horizontal plane anchor's transform, whose y axis is the plane's normal.
  public var plane: simd_float4x4?

  public init(intrinsics: simd_float3x3, resolution: CGSize, transform: simd_float4x4, plane: simd_float4x4?) {
    self.intrinsics = intrinsics
    self.resolution = resolution
    self.transform = transform
    self.plane = plane
  }

  /// Where a point in the upright image meets the table, in world coordinates, or nil where its ray never does.
  public func ground(_ point: CGPoint) -> SIMD3<Float>? {
    guard let plane else { return nil }
    let x = Float(point.y), y = Float(resolution.height - point.x)
    let k = intrinsics
    let ray = transform * SIMD4((x - k[2][0]) / k[0][0], -(y - k[2][1]) / k[1][1], -1, 0)
    let direction = SIMD3(ray.x, ray.y, ray.z)
    let origin = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    let normal = SIMD3(plane.columns.1.x, plane.columns.1.y, plane.columns.1.z)
    let onPlane = SIMD3(plane.columns.3.x, plane.columns.3.y, plane.columns.3.z)
    let facing = dot(direction, normal)
    guard facing != 0 else { return nil }
    let t = dot(onPlane - origin, normal) / facing
    return t > 0 ? origin + t * direction : nil
  }

  /// A box's size on the table, in metres: along its bottom edge, then from that edge to its top edge's. A tile lying
  /// on the table measures as a tile; one standing on a rack reaches far behind it, or never meets it (infinity).
  public func footprint(_ box: CGRect) -> SIMD2<Float>? {
    guard let bl = ground(CGPoint(x: box.minX, y: box.maxY)), let br = ground(CGPoint(x: box.maxX, y: box.maxY))
    else { return nil }
    let width = distance(bl, br)
    guard let tl = ground(CGPoint(x: box.minX, y: box.minY)), let tr = ground(CGPoint(x: box.maxX, y: box.minY))
    else { return SIMD2(width, .infinity) }
    return SIMD2(width, distance((tl + tr) / 2, (bl + br) / 2))
  }
}
