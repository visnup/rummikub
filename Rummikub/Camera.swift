import AVFoundation
import CoreImage
import SwiftUI

/// The back camera, as a session to preview and a stream of upright frames a few times a second.
nonisolated final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  let frames: AsyncStream<CGImage>
  private let continuation: AsyncStream<CGImage>.Continuation
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
    guard let device else { return [:] }
    let gains = device.deviceWhiteBalanceGains
    return [
      "iso": device.iso, "exposure": device.exposureDuration.seconds, "lensPosition": device.lensPosition,
      "whiteBalanceGains": [gains.redGain, gains.greenGain, gains.blueGain],
      "fieldOfView": device.activeFormat.videoFieldOfView, "zoom": device.videoZoomFactor, "zoomLabel": device.videoZoomFactor / wide,
      "lens": device.activePrimaryConstituent?.deviceType.rawValue ?? device.deviceType.rawValue,
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

  /// Starts or stops the camera, off the main thread, since starting blocks.
  func run(_ on: Bool) {
    control.async {
      if on && !self.session.isRunning {
        self.session.startRunning()
      } else if !on && self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard Date().timeIntervalSince(last) > 0.3, let buffer = sampleBuffer.imageBuffer else { return }
    let image = CIImage(cvPixelBuffer: buffer)
    guard let frame = context.createCGImage(image, from: image.extent) else { return }
    last = Date()
    continuation.yield(frame)
  }
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
