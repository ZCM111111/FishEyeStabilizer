import Foundation
import CoreVideo
import CoreMedia

protocol CameraFrameDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutputPixelBuffer pixelBuffer: CVPixelBuffer, timestamp: CMTime)
}

final class CameraManager: NSObject, ObservableObject {
    @Published private(set) var isSessionRunning = false
    var targetFrameRate: Int32 = 60
    weak var delegate: CameraFrameDelegate?
    func startSession() { isSessionRunning = true }
    func stopSession() { isSessionRunning = false }
    func toggleCamera() {}
}
