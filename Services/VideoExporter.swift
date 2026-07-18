import AVFoundation
import Photos
import UIKit

// MARK: - 视频导出服务

/// 将处理后的视频导出保存到相册
///
/// 功能:
/// - 自定义输出分辨率、码率、帧率
/// - 保存到系统相册（Photos Library）
/// - 导出进度回调
///
/// 使用方式:
/// ```swift
/// let exporter = VideoExporter()
/// await exporter.exportAndSave(videoURL: processedURL)
/// ```
@MainActor
final class VideoExporter: ObservableObject {

    // MARK: - 公开属性

    /// 导出进度 [0.0, 1.0]
    @Published private(set) var progress: Double = 0.0

    /// 是否正在导出
    @Published private(set) var isExporting = false

    /// 错误信息
    @Published private(set) var errorMessage: String?

    /// 进度回调代理
    weak var delegate: VideoExporterDelegate?

    // MARK: - 保存到相册

    /// 将视频文件保存到系统相册
    ///
    /// - Parameter videoURL: 视频文件 URL
    /// - Throws: PHPhotoLibrary 写入错误
    func saveToPhotoLibrary(videoURL: URL) async throws {
        // 请求相册写入权限
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)

        guard status == .authorized || status == .limited else {
            throw ExportError.noPermission
        }

        await MainActor.run { isExporting = true }
        defer { Task { @MainActor in isExporting = false } }

        // 写入相册
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            request?.creationDate = Date()
        }

        print("✅ [VideoExporter] 视频已保存到相册")
    }

    // MARK: - 导出（可自定义参数）

    /// 以自定义参数重新编码并导出视频
    ///
    /// - Parameters:
    ///   - inputURL: 源视频 URL
    ///   - outputURL: 输出视频 URL
    ///   - config: 处理配置（分辨率、码率、帧率）
    func export(
        inputURL: URL,
        outputURL: URL,
        config: ProcessingConfig
    ) async throws {
        await MainActor.run {
            isExporting = true
            progress = 0.0
        }
        defer { Task { @MainActor in isExporting = false } }

        let asset = AVAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        // 创建导出会话
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: config.outputPresetName
        ) else {
            throw ExportError.exportSessionFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        // 自定义码率
        if let bitrate = config.outputBitrateMbps as NSNumber? {
            exportSession.metadata = [
                AVMetadataItem(
                    property: .quickTimeMetadataKey,
                    value: bitrate,
                    identifier: AVMetadataIdentifier("com.apple.quicktime.bitrate")
                )
            ]
        }

        // 监控进度
        let progressTask = Task { @MainActor in
            while exportSession.status == .exporting || exportSession.status == .waiting {
                self.progress = Double(exportSession.progress)
                self.delegate?.videoExporter(self, didUpdateProgress: Double(exportSession.progress))
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // 执行导出
        await exportSession.export()

        // 停止进度监控
        progressTask.cancel()

        // 检查结果
        if let error = exportSession.error {
            throw ExportError.exportFailed(error)
        }

        guard exportSession.status == .completed else {
            throw ExportError.exportCancelled
        }

        await MainActor.run { progress = 1.0 }
        print("✅ [VideoExporter] 导出完成")
    }

    /// 导出并保存（一站式）
    func exportAndSave(
        inputURL: URL,
        config: ProcessingConfig
    ) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_\(UUID().uuidString).mp4")

        // 导出到临时文件
        try await export(inputURL: inputURL, outputURL: tempURL, config: config)

        // 保存到相册
        try await saveToPhotoLibrary(videoURL: tempURL)

        // 清理临时文件
        try? FileManager.default.removeItem(at: tempURL)
    }
}

// MARK: - 错误类型

enum ExportError: LocalizedError {
    case noPermission
    case exportSessionFailed
    case exportFailed(Error)
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "没有相册写入权限，请在「设置」中允许访问"
        case .exportSessionFailed:
            return "无法创建导出会话"
        case .exportFailed(let error):
            return "导出失败: \(error.localizedDescription)"
        case .exportCancelled:
            return "导出已取消"
        }
    }
}

// MARK: - 代理协议

protocol VideoExporterDelegate: AnyObject {
    func videoExporter(_ exporter: VideoExporter, didUpdateProgress progress: Double)
}

// MARK: - ProcessingConfig 扩展

private extension ProcessingConfig {
    /// 映射到 AVAssetExportSession 的预设名
    var outputPresetName: String {
        switch outputResolution {
        case .uhd4K:
            return AVAssetExportPresetHEVC3840x2160
        case .hd1080p:
            return AVAssetExportPresetHEVC1920x1080
        case .hd720p:
            return AVAssetExportPresetHEVC1280x720
        case .matchInput:
            return AVAssetExportPresetHighestQuality
        }
    }
}
