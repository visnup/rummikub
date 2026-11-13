import ARKit
import AVFoundation
import CoreImage
import RummikubKit
import SwiftUI

/// An upright frame, where the camera was, and the planes ARKit has found.
nonisolated struct Frame: Sendable {
  let image: CGImage
  var pose: Pose
  var planes = [Plane]()
  var tracking: String
  /// Where a person, like a hand reaching in, covers the frame.
  var mask: World.Mask?

  struct Plane: Sendable {
    let transform: simd_float4x4
    let extent: SIMD2<Float>
    let classification: String
  }
}

/// The back camera through ARKit, as a session to preview and a stream of upright frames a few times a second.
nonisolated final class Camera: NSObject, ARSessionDelegate, @unchecked Sendable {
  let session = ARSession()
  let frames: AsyncStream<Frame>
  private let continuation: AsyncStream<Frame>.Continuation
  private let context = CIContext()
  /// Only touched on ARKit's delegate queue.
  private var last = Date.distantPast

  private let configuration: ARWorldTrackingConfiguration = {
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = .horizontal
    // Hands over tiles, so the world table doesn't take them as gone.
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
      configuration.frameSemantics.insert(.personSegmentation)
    }
    // The size the models were made on.
    if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
      $0.imageResolution == CGSize(width: 1920, height: 1080) && $0.framesPerSecond == 30
    }) {
      configuration.videoFormat = format
    }
    return configuration
  }()

  /// What the camera is set to, for a capture's notes.
  static var settings: [String: Any] { ["lens": "arkit", "arkit": arkit] }

  /// What ARKit could give on this phone: LiDAR depth, and each camera and size it can track with.
  static var arkit: [String: Any] {
    [
      "sceneDepth": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
      "personSegmentation": ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation),
      "formats": ARWorldTrackingConfiguration.supportedVideoFormats.map {
        "\($0.captureDeviceType.rawValue) \(Int($0.imageResolution.width))x\(Int($0.imageResolution.height)) \($0.framesPerSecond)fps"
          + ($0.isRecommendedForHighResolutionFrameCapturing ? " high-res" : "")
      },
    ]
  }

  override init() {
    (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    super.init()
  }

  /// False when there's no camera to use. The simulator never uses one, so it replays a recording.
  func start() async -> Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      guard ARWorldTrackingConfiguration.isSupported, await AVCaptureDevice.requestAccess(for: .video) else { return false }
      session.delegateQueue = DispatchQueue(label: "ar")
      session.delegate = self
      session.run(configuration)
      return true
    #endif
  }

  /// Starts or stops the camera. ARKit keeps its planes across a pause: reset, it had no table for a while, and
  /// nothing was read. `World` starts over instead (`Game.restart`).
  func run(_ on: Bool) {
    on ? session.run(configuration) : session.pause()
  }

  /// Where the camera is now, for drawing between reads; no plane, since only the read frame's is used.
  var pose: Pose? {
    guard let camera = session.currentFrame?.camera else { return nil }
    return Pose(intrinsics: camera.intrinsics, resolution: camera.imageResolution, transform: camera.transform, plane: nil)
  }

  /// Copies what's needed out of each frame, since holding an ARFrame stalls the session.
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard Date().timeIntervalSince(last) > 0.2 else { return }
    let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
    guard let upright = context.createCGImage(image, from: image.extent) else { return }
    last = Date()
    let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
    let camera = frame.camera
    // The table: the highest plane below the camera, not the floor.
    let table = planes.filter { $0.transform.columns.3.y < camera.transform.columns.3.y }
      .max { $0.transform.columns.3.y < $1.transform.columns.3.y }
    continuation.yield(Frame(
      image: upright,
      pose: Pose(intrinsics: camera.intrinsics, resolution: camera.imageResolution, transform: camera.transform,
        plane: table?.transform),
      planes: planes.map {
        Frame.Plane(transform: $0.transform, extent: [$0.planeExtent.width, $0.planeExtent.height],
          classification: "\($0.classification)")
      },
      tracking: "\(camera.trackingState)",
      mask: frame.segmentationBuffer.map(Self.mask)))
  }

  private static func mask(_ buffer: CVPixelBuffer) -> World.Mask {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return World.Mask(width: width, height: height, bytes: (0..<height).flatMap { y in UnsafeBufferPointer(start: base + y * row, count: width) })
  }
}

/// The camera, one view moved between the tabs, since a session shows in one at a time.
struct ARPreview: UIViewRepresentable {
  let session: ARSession

  private static var shared: ARSCNView?

  func makeUIView(context: Context) -> Holder {
    if Self.shared == nil {
      let view = ARSCNView()
      view.session = session
      view.debugOptions = [.showFeaturePoints]
      Self.shared = view
    }
    return Holder(Self.shared!)
  }

  func updateUIView(_ view: Holder, context: Context) {}
}

/// Holds a view shared between the tabs, taking it back whenever it's on screen: SwiftUI removing the other tab's
/// holder took the view with it, and the camera went black while ARKit and reading carried on.
final class Holder: UIView {
  let child: UIView

  init(_ child: UIView) {
    self.child = child
    super.init(frame: .zero)
    child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder: NSCoder) { fatalError() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, child.superview !== self {
      child.frame = bounds
      addSubview(child)
    }
  }
}
