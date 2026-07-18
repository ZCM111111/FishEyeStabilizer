import Foundation

protocol CameraFrameDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutputPixelBuffer pixelBuffer: Any, timestamp: Any)
}

final class CameraManager: NSObject, ObservableObject {
    @Published private(set) var isSessionRunning = false
    @Published var cameraPosition: Any = "back"
    var sessionPreset: Any = "hd4K"
    var targetFrameRate: Int32 = 60
    weak var delegate: CameraFrameDelegate?
    func startSession() { isSessionRunning = true }
    func stopSession() { isSessionRunning = false }
    func toggleCamera() {}
}
