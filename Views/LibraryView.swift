import SwiftUI
@preconcurrency import PhotosUI
@preconcurrency import AVKit

// MARK: - 相册视图

/// 显示系统相册中的视频列表 + 视频选择器
///
/// 功能:
/// - 视频缩略图网格
/// - 点击选中 → 跳转到处理页面
/// - PHPicker 导入新视频
/// - 下拉刷新
///
struct LibraryView: View {

    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var processingVM: ProcessingViewModel

    // MARK: - 状态

    @State private var showPicker = false
    @State private var showProcessing = false
    @State private var selectedPickerItem: PhotosPickerItem?

    // 网格布局
    private let columns = [
        GridItem(.adaptive(minimum: 110), spacing: 2)
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if libraryVM.isLoading {
                    loadingView
                } else if libraryVM.videos.isEmpty {
                    emptyView
                } else {
                    videoGrid
                }
            }
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    importButton
                }
                ToolbarItem(placement: .topBarLeading) {
                    refreshButton
                }
            }
            .navigationDestination(isPresented: $showProcessing) {
                if let video = libraryVM.selectedVideo {
                    ProcessingView(
                        viewModel: processingVM,
                        sourceVideo: video
                    )
                }
            }
        }
    }

    // MARK: - 视频网格

    private var videoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(libraryVM.videos) { video in
                    videoCell(video)
                        .onTapGesture {
                            libraryVM.selectVideo(video)
                            showProcessing = true
                        }
                }
            }
            .padding(2)
        }
        .refreshable {
            await libraryVM.loadVideos()
        }
    }

    /// 单个视频格子
    private func videoCell(_ video: LibraryViewModel.VideoItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // 缩略图
            if let thumbnail = video.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 110)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: 110)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.5))
                    }
            }

            // 时长标签
            Text(video.formattedDuration)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
    }

    // MARK: - 空状态

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("相册中没有视频")
                .font(.title3)
                .foregroundColor(.gray)
            Text("使用 iPhone 录制或在「拍摄」Tab 中录制")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
        }
    }

    // MARK: - 加载中

    private var loadingView: some View {
        ProgressView("加载视频...")
            .foregroundColor(.gray)
    }

    // MARK: - 按钮

    /// 导入按钮
    private var importButton: some View {
        PhotosPicker(
            selection: $selectedPickerItem,
            matching: .videos,
            photoLibrary: .shared()
        ) {
            Image(systemName: "plus")
        }
        .onChange(of: selectedPickerItem) { _, newItem in
            guard let item = newItem else { return }
            Task {
                await libraryVM.handlePickerResult(item)
                if libraryVM.selectedVideo != nil {
                    showProcessing = true
                }
            }
        }
    }

    /// 刷新按钮
    private var refreshButton: some View {
        Button {
            Task { await libraryVM.loadVideos() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(libraryVM.isLoading)
    }
}

// MARK: - 预览

#Preview {
    LibraryView(
        libraryVM: LibraryViewModel(),
        processingVM: ProcessingViewModel()
    )
}
