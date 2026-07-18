@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import UIKit

// MARK: - 视频导出服务

@MainActor
final class VideoExporter: ObservableObject {
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    weak var delegate: VideoExporterDelegate?

    func saveToPhotoLibrary(videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.noPermission }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
    }

    func export(inputURL: URL, outputURL: URL, config: ProcessingConfig) async throws {
        let asset = AVAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: config.outputPresetName) else {
            throw ExportError.exportSessionFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        await session.export()
        if let error = session.error { throw ExportError.exportFailed(error) }
    }

    func exportAndSave(inputURL: URL, config: ProcessingConfig) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_\(UUID().uuidString).mp4")
        try await export(inputURL: inputURL, outputURL: tempURL, config: config)
        try await saveToPhotoLibrary(videoURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
    }
}

enum ExportError: LocalizedError {
    case noPermission, exportSessionFailed, exportFailed(Error), exportCancelled
    var errorDescription: String? { "导出失败" }
}

protocol VideoExporterDelegate: AnyObject {
    func videoExporter(_ exporter: VideoExporter, didUpdateProgress progress: Double)
}
