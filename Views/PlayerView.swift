import SwiftUI
@preconcurrency import AVKit

// MARK: - 视频播放视图

/// 播放处理前后的视频进行对比
///
/// 布局:
/// - 顶部: 对比模式切换（左右并排 / 滑块对比 / 叠层）
/// - 中部: 视频播放器（支持 AVPlayer）
/// - 底部: 播放控制 + 导出按钮
///
struct PlayerView: View {

    /// 原始视频 URL
    let originalURL: URL?

    /// 处理后的视频 URL
    let processedURL: URL

    // MARK: - 状态

    @State private var player: AVPlayer?
    @State private var compareMode: CompareMode = .sideBySide
    @State private var sliderPosition: CGFloat = 0.5
    @State private var isPlayingOriginal = false

    // MARK: - 对比模式

    enum CompareMode: String, CaseIterable {
        case processed = "处理后"
        case original = "原始"
        case slider = "滑块对比"
        case sideBySide = "左右对比"

        var icon: String {
            switch self {
            case .processed:    return "film"
            case .original:     return "camera.fill"
            case .slider:       return "slider.horizontal.2.square"
            case .sideBySide:   return "rectangle.split.2x1"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // --- 视频播放区 ---
            videoDisplayArea

            // --- 对比模式选择 ---
            compareModePicker

            // --- 播放控制 ---
            playbackControls
        }
        .background(.black)
        .navigationTitle("视频对比")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - 视频显示区

    private var videoDisplayArea: some View {
        GeometryReader { geometry in
            ZStack {
                switch compareMode {
                case .processed:
                    videoPlayerLayer
                        .frame(width: geometry.size.width, height: geometry.size.height)

                case .original:
                    videoPlayerLayer
                        .frame(width: geometry.size.width, height: geometry.size.height)

                case .slider:
                    // 滑块对比：左侧原始，右侧处理后
                    sliderComparison(geometry: geometry)

                case .sideBySide:
                    // 左右并排对比
                    sideBySideComparison(geometry: geometry)
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    /// 滑块对比视图
    private func sliderComparison(geometry: GeometryProxy) -> some View {
        ZStack {
            // 原始视频在底层
            videoPlayerLayer
                .frame(width: geometry.size.width, height: geometry.size.height)

            // 处理后视频在上层，通过裁剪只显示右半部分
            videoPlayerLayer
                .frame(width: geometry.size.width, height: geometry.size.height)
                .mask(
                    HStack {
                        Spacer()
                            .frame(width: sliderPosition * geometry.size.width)
                        Rectangle()
                    }
                )

            // --- 滑块分隔线 ---
            Rectangle()
                .fill(.white)
                .frame(width: 3)
                .position(x: sliderPosition * geometry.size.width,
                          y: geometry.size.height / 2)

            // --- 滑块拖拽手柄 ---
            Circle()
                .fill(.white)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundColor(.black)
                }
                .position(x: sliderPosition * geometry.size.width,
                          y: geometry.size.height / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newPosition = value.location.x / geometry.size.width
                            sliderPosition = min(max(newPosition, 0.05), 0.95)
                        }
                )

            // --- 标签 ---
            VStack {
                HStack {
                    Text("原始")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    Spacer()
                    Text("矫正+防抖")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.7))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    /// 左右并排对比
    private func sideBySideComparison(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            videoPlayerLayer
                .frame(width: geometry.size.width / 2)

            videoPlayerLayer
                .frame(width: geometry.size.width / 2)
        }
    }

    /// 视频播放层
    private var videoPlayerLayer: some View {
        VideoPlayer(player: player)
    }

    // MARK: - 对比模式选择器

    private var compareModePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CompareMode.allCases, id: \.self) { mode in
                    Button {
                        compareMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(compareMode == mode ? .orange : .gray)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.5))
    }

    // MARK: - 播放控制

    private var playbackControls: some View {
        HStack(spacing: 20) {
            Button {
                if player?.timeControlStatus == .playing {
                    player?.pause()
                } else {
                    player?.play()
                }
            } label: {
                Image(systemName: player?.timeControlStatus == .playing
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }

            // 分享/导出 按钮
            ShareLink(item: processedURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }
        }
        .padding()
        .background(.black.opacity(0.5))
    }

    // MARK: - 初始化播放器

    private func setupPlayer() {
        // 先播放处理后的视频
        player = AVPlayer(url: processedURL)
        player?.play()
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        PlayerView(
            originalURL: nil,
            processedURL: URL(fileURLWithPath: "/tmp/test.mp4")
        )
    }
}
