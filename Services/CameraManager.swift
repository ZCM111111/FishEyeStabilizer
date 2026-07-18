@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreMedia
import Combine

protocol CameraFrameDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, timestamp: CMTime)
}

final class CameraManager: NSObject, ObservableObject {
    private(set) var session: AVCaptureSession
    private(set) var videoDevice: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    weak var delegate: CameraFrameDelegate?
    @Published private(set) var isSessionRunning = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    var sessionPreset: AVCaptureSession.Preset = .hd4K3840x2160
    var targetFrameRate: Int32 = 60
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.session = AVCaptureSession()
        super.init()
    }

    func startSession() { isSessionRunning = true }
    func stopSession() { isSessionRunning = false }
    func toggleCamera() {}
}
