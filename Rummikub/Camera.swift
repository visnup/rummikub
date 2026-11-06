import AVFoundation
import CoreImage
import SwiftUI

/// The back camera, as a session to preview and a stream of upright frames a few times a second.
nonisolated final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  let frames: AsyncStream<CGImage>
  private let continuation: AsyncStream<CGImage>.Continuation
  private let context = CIContext()
  /// Only touched on the capture queue.
  private var last = Date.distantPast

  override init() {
    (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    super.init()
  }

  /// False when there's no camera to use. The simulator never uses one, so it shows the demo.
  func start() async -> Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      guard let device = AVCaptureDevice.default(for: .video), await AVCaptureDevice.requestAccess(for: .video),
        let input = try? AVCaptureDeviceInput(device: device)
      else { return false }
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

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.preview.session = session
    view.preview.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {}

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}
