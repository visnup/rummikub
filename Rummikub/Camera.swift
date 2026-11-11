import ARKit
import AVFoundation
import CoreImage
import RummikubKit
import SwiftUI

/// An upright frame, and with ARKit where the camera was and the planes it has found.
nonisolated struct Frame: Sendable {
  let image: CGImage
  var pose: Pose?
  var planes = [Plane]()
  var tracking = ""

  struct Plane: Sendable {
    let transform: simd_float4x4
    let extent: SIMD2<Float>
    let classification: String
  }
}

/// The back camera, as a session to preview and a stream of upright frames a few times a second. With `ar`, ARKit's
/// session runs it instead, which can't zoom: it tracks only with the wide lens.
nonisolated final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ARSessionDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  let arSession = ARSession()
  private(set) var ar = false
  let frames: AsyncStream<Frame>
  private let continuation: AsyncStream<Frame>.Continuation
  private let context = CIContext()
  private var device: AVCaptureDevice?
  /// Only touched on the capture queue.
  private var last = Date.distantPast
  /// The device zoom factor that shows as "1×".
  private var wide: CGFloat = 1

  /// The zooms to offer, as the Camera app labels them: 0.5× where there's an ultra wide.
  var zooms: [Double] { wide > 1 ? [0.5, 1, 2] : [1, 2] }

  /// Zooms to a factor as the Camera app labels it, so 0.5 is the ultra wide.
  func zoom(to label: Double) {
    guard let device, (try? device.lockForConfiguration()) != nil else { return }
    device.videoZoomFactor = min(max(CGFloat(label) * wide, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    device.unlockForConfiguration()
  }

  /// What the camera is set to right now, for a capture's notes.
  var settings: [String: Any] {
    if ar { return ["lens": "arkit", "arkit": Self.arkit] }
    guard let device else { return [:] }
    let gains = device.deviceWhiteBalanceGains
    return [
      "iso": device.iso, "exposure": device.exposureDuration.seconds, "lensPosition": device.lensPosition,
      "whiteBalanceGains": [gains.redGain, gains.greenGain, gains.blueGain],
      "fieldOfView": device.activeFormat.videoFieldOfView, "zoom": device.videoZoomFactor, "zoomLabel": device.videoZoomFactor / wide,
      "lens": device.activePrimaryConstituent?.deviceType.rawValue ?? device.deviceType.rawValue,
      "arkit": Self.arkit,
    ]
  }

  /// What ARKit could give on this phone: LiDAR depth, and each camera and size it can track with.
  static var arkit: [String: Any] {
    [
      "sceneDepth": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
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

  /// False when there's no camera to use. The simulator never uses one, so it shows the demo.
  func start() async -> Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      // A virtual device switches lenses as it zooms, so the ultra wide is in reach.
      guard
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
          ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
          ?? AVCaptureDevice.default(for: .video),
        await AVCaptureDevice.requestAccess(for: .video),
        let input = try? AVCaptureDeviceInput(device: device)
      else { return false }
      self.device = device
      // A zoom factor of 1 is the ultra wide; the wide lens, "1×", starts at the first switch-over.
      wide = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) } ?? 1
      // Widest first: a whole table fits from closer.
      zoom(to: zooms[0])
      session.sessionPreset = .hd1920x1080
      session.addInput(input)
      let output = AVCaptureVideoDataOutput()
      output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))
      session.addOutput(output)
      output.connection(with: .video)?.videoRotationAngle = 90
      session.startRunning()
      return true
    #endif
  }

  private let control = DispatchQueue(label: "camera control")

  static var arSupported: Bool { ARWorldTrackingConfiguration.isSupported }

  /// Hands the camera between AVFoundation and ARKit, which can't both have it.
  func use(ar: Bool) {
    control.async {
      self.ar = ar
      if ar {
        self.session.stopRunning()
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        // The size the models were made on.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
          $0.imageResolution == CGSize(width: 1920, height: 1080) && $0.framesPerSecond == 30
        }) {
          configuration.videoFormat = format
        }
        self.arSession.delegateQueue = DispatchQueue(label: "ar")
        self.arSession.delegate = self
        self.arSession.run(configuration)
      } else {
        self.arSession.pause()
        self.session.startRunning()
      }
    }
  }

  /// Starts or stops the camera, off the main thread, since starting blocks.
  func run(_ on: Bool) {
    if ar {
      on ? arSession.run(arSession.configuration!) : arSession.pause()
      return
    }
    control.async {
      if on && !self.session.isRunning {
        self.session.startRunning()
      } else if !on && self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard Date().timeIntervalSince(last) > 0.2, let buffer = sampleBuffer.imageBuffer else { return }
    let image = CIImage(cvPixelBuffer: buffer)
    guard let frame = context.createCGImage(image, from: image.extent) else { return }
    last = Date()
    continuation.yield(Frame(image: frame))
  }

  /// Where the camera is now, for drawing between reads; no plane, since only the read frame's is used.
  var pose: Pose? {
    guard ar, let camera = arSession.currentFrame?.camera else { return nil }
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
      tracking: "\(camera.trackingState)"))
  }
}

struct ARPreview: UIViewRepresentable {
  let session: ARSession

  private static var shared: ARSCNView?

  func makeUIView(context: Context) -> ARSCNView {
    if let view = Self.shared { return view }
    let view = ARSCNView()
    view.session = session
    view.debugOptions = [.showFeaturePoints]
    Self.shared = view
    return view
  }

  func updateUIView(_ view: ARSCNView, context: Context) {}
}

struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  /// One view, moved between the tabs: attaching the session to a new preview layer on every switch locked up the
  /// app for a moment.
  private static var shared: PreviewView?

  func makeUIView(context: Context) -> PreviewView {
    if let view = Self.shared { return view }
    let view = PreviewView()
    view.preview.session = session
    view.preview.videoGravity = .resizeAspectFill
    Self.shared = view
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {}

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}
