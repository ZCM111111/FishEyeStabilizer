import Foundation

// MARK: - 视频导出服务 (stub for CI)

@MainActor
final class VideoExporter: ObservableObject {
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    weak var delegate: VideoExporterDelegate?

    func exportAndSave(inputURL: URL, config: ProcessingConfig) async throws {
        // CI stub
    }
}

enum ExportError: LocalizedError {
    case noPermission, exportSessionFailed, exportFailed(Error), exportCancelled
    var errorDescription: String? { "导出失败" }
}

protocol VideoExporterDelegate: AnyObject {
    func videoExporter(_ exporter: VideoExporter, didUpdateProgress progress: Double)
}
