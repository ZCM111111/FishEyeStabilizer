import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - 相册视频库 ViewModel

/// 管理相册视频的读取、选择和预览
///
/// 支持:
/// - 系统相册视频列表
/// - PHPicker 选择器集成
/// - 视频缩略图生成
/// - 视频基本元数据提取（分辨率、帧率、时长）
///
@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: - 视频列表

    /// 相册中的所有视频
    @Published var videos: [VideoItem] = []

    /// 当前选中的视频
    @Published var selectedVideo: VideoItem?

    /// 是否正在加载
    @Published var isLoading = false

    /// 加载错误
    @Published var errorMessage: String?

    // MARK: - 视频元数据

    /// 选中视频的时长（格式化字符串）
    @Published var durationString: String = ""

    /// 选中视频的分辨率
    @Published var resolutionString: String = ""

    /// 选中视频的帧率
    @Published var frameRateString: String = ""

    // MARK: - 数据模型

    struct VideoItem: Identifiable, Hashable {
        let id: String            // PHAsset.localIdentifier
        let asset: PHAsset
        let creationDate: Date?
        let duration: TimeInterval

        /// 缩略图（异步加载）
        var thumbnail: UIImage?

        var formattedDuration: String {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: VideoItem, rhs: VideoItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - 初始化

    init() {
        Task {
            await requestPermissionAndLoad()
        }
    }

    // MARK: - 权限与加载

    /// 请求相册权限并加载视频列表
    func requestPermissionAndLoad() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)

        switch status {
        case .authorized, .limited:
            await loadVideos()
        case .denied, .restricted:
            errorMessage = "请在「设置」中允许访问相册"
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    /// 从相册加载所有视频
    func loadVideos() async {
        await MainActor.run { isLoading = true }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        fetchOptions.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.video.rawValue
        )

        let fetchResult = PHAsset.fetchAssets(with: .video, options: fetchOptions)

        var items: [VideoItem] = []
        fetchResult.enumerateObjects { asset, _, _ in
            items.append(VideoItem(
                id: asset.localIdentifier,
                asset: asset,
                creationDate: asset.creationDate,
                duration: asset.duration
            ))
        }

        await MainActor.run {
            self.videos = items
            self.isLoading = false
        }

        // 异步加载缩略图
        await loadThumbnails(for: items)
    }

    /// 加载视频缩略图
    private func loadThumbnails(for items: [VideoItem]) async {
        let imageManager = PHImageManager.default()
        let targetSize = CGSize(width: 200, height: 200)

        for item in items {
            let thumbnail = await withCheckedContinuation { continuation in
                imageManager.requestImage(
                    for: item.asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: nil
                ) { image, _ in
                    continuation.resume(returning: image)
                }
            }

            if let thumbnail = thumbnail {
                await MainActor.run {
                    if let index = videos.firstIndex(where: { $0.id == item.id }) {
                        var updated = videos[index]
                        updated.thumbnail = thumbnail
                        videos[index] = updated
                    }
                }
            }
        }
    }

    // MARK: - 选择视频

    /// 选择一个视频并加载其元数据
    func selectVideo(_ item: VideoItem) {
        selectedVideo = item
        loadMetadata(for: item)
    }

    /// 通过 PHPicker 选择视频
    func handlePickerResult(_ result: PHPickerResult) async {
        guard let assetId = result.assetIdentifier else { return }

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetId],
            options: nil
        )

        guard let asset = fetchResult.firstObject else { return }

        let item = VideoItem(
            id: asset.localIdentifier,
            asset: asset,
            creationDate: asset.creationDate,
            duration: asset.duration
        )

        await MainActor.run {
            selectedVideo = item
        }
        loadMetadata(for: item)
    }

    // MARK: - 元数据提取

    /// 加载视频的详细元数据
    private func loadMetadata(for item: VideoItem) {
        // 时长
        durationString = item.formattedDuration

        // 分辨率
        let pixelWidth = item.asset.pixelWidth
        let pixelHeight = item.asset.pixelHeight
        resolutionString = "\(pixelWidth)×\(pixelHeight)"

        // 帧率（异步加载）
        Task {
            let fps = await loadFrameRate(for: item)
            await MainActor.run {
                frameRateString = fps.map { "\(Int($0))fps" } ?? "未知"
            }
        }
    }

    /// 获取视频的实际帧率
    private func loadFrameRate(for item: VideoItem) async -> Float? {
        let resources = PHAssetResource.assetResources(for: item.asset)
        guard let videoResource = resources.first else { return nil }

        // 通过 AVAsset 获取帧率
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat

            PHImageManager.default().requestAVAsset(
                forVideo: item.asset,
                options: options
            ) { avAsset, _, _ in
                guard let asset = avAsset else {
                    continuation.resume(returning: nil)
                    return
                }

                Task {
                    guard let track = try? await asset.loadTracks(
                        withMediaCharacteristic: .visual
                    ).first else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let frameRate = try? await track.load(.nominalFrameRate)
                    continuation.resume(returning: frameRate)
                }
            }
        }
    }
}
