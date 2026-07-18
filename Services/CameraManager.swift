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
        configureSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition) else {
            session.commitConfiguration(); return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.inputs.forEach { session.removeInput($0) }
                session.addInput(input)
                self.videoDevice = camera
                try configureCameraDevice(camera)
            }
        } catch { print("Camera input error: \(error)") }
        if session.canAddOutput(videoOutput) {
            session.outputs.forEach { session.removeOutput($0) }
            session.addOutput(videoOutput)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)
        }
        session.commitConfiguration()
    }

    private func configureCameraDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        if let format = findBestFormat(for: device, targetFPS: targetFrameRate) {
            device.activeFormat = format
            let fpsRange = CMTimeMake(value: 1, timescale: targetFrameRate)
            device.activeVideoMinFrameDuration = fpsRange
            device.activeVideoMaxFrameDuration = fpsRange
        }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        device.unlockForConfiguration()
    }

    private func findBestFormat(for device: AVCaptureDevice, targetFPS: Int32) -> AVCaptureDevice.Format? {
        var bestFormat: AVCaptureDevice.Format?
        var bestPixels: Int32 = 0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 3840 else { continue }
            for range in format.videoSupportedFrameRateRanges {
                if Int32(range.maxFrameRate) >= targetFPS, Int32(range.minFrameRate) <= targetFPS, dims.width > bestPixels {
                    bestFormat = format; bestPixels = dims.width
                }
            }
        }
        return bestFormat
    }

    func startSession() { session.startRunning(); isSessionRunning = session.isRunning }
    func stopSession() { session.stopRunning(); isSessionRunning = session.isRunning }
    func toggleCamera() {}
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.cameraManager(self, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
