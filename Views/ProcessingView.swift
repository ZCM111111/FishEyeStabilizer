import SwiftUI
@preconcurrency import Photos
@preconcurrency import AVKit

// MARK: - 视频处理视图

/// 视频处理主界面
///
/// 功能分区:
/// 1. 顶部: 视频信息 + 源预览
/// 2. 中部: 鱼眼参数配置（自动检测/预设/手动）
/// 3. 下部: 防抖配置 + 处理按钮 + 进度条
///
struct ProcessingView: View {

    @ObservedObject var viewModel: ProcessingViewModel
    let sourceVideo: LibraryViewModel.VideoItem

    // MARK: - 状态

    @State private var showPresetPicker = false
    @State private var showingComparison = false

    /// 用于在视图出现时自动加载视频
    @State private var didLoadVideo = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // --- 视频信息 ---
                videoInfoHeader

                // --- 鱼眼矫正配置 ---
                fisheyeSection

                // --- 防抖配置 ---
                stabilizationSection

                // --- 预览对比按钮 ---
                comparisonButton

                // --- 处理按钮 + 进度 ---
                processSection

                // --- 错误信息 ---
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("视频处理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !didLoadVideo {
                didLoadVideo = true
                await viewModel.loadVideoFromAsset(sourceVideo.asset)
            }
        }
        .sheet(isPresented: $showPresetPicker) {
            PresetPickerView(
                presets: viewModel.lensPresetService.allPresets,
                selectedPreset: viewModel.config.lensProfile,
                onSelect: { viewModel.applyPreset($0) }
            )
        }
    }

    // MARK: - 视频信息头部

    private var videoInfoHeader: some View {
        HStack {
            // 缩略图
            if let thumbnail = sourceVideo.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.sourceVideoTitle.isEmpty
                     ? "视频 \(sourceVideo.creationDate?.formatted() ?? "")"
                     : viewModel.sourceVideoTitle)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(sourceVideo.formattedDuration, systemImage: "clock")
                    Label("\(sourceVideo.asset.pixelWidth)×\(sourceVideo.asset.pixelHeight)",
                          systemImage: "rectangle.on.rectangle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 鱼眼矫正分区

    private var fisheyeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 分区标题
            sectionHeader(
                icon: "camera.lens.fill",
                title: "鱼眼矫正",
                color: .blue
            )

            // --- 自动检测按钮 ---
            autoDetectButton

            // --- 预设选择 ---
            presetSelector

            // --- 矫正启用开关 ---
            Toggle("启用鱼眼矫正", isOn: $viewModel.fisheyeCorrector.isEnabled)
                .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 自动检测按钮
    private var autoDetectButton: some View {
        Button {
            Task { await viewModel.runAutoDetection() }
        } label: {
            HStack {
                if viewModel.stage == .analyzing {
                    ProgressView()
                        .tint(.white)
                    Text("正在分析畸变参数...")
                } else {
                    Image(systemName: "wand.and.stars")
                    Text("自动检测鱼眼参数")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(viewModel.stage == .analyzing)
    }

    /// 预设选择器行
    private var presetSelector: some View {
        HStack {
            if let preset = viewModel.config.lensProfile {
                // 已选择预设
                Label(preset.displayName, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
            } else {
                Label("未选择镜头预设", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }

            Spacer()

            Button("选择预设") {
                showPresetPicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 防抖配置分区

    private var stabilizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "gyroscope",
                title: "地平线防抖",
                color: .orange
            )

            // --- 防抖模式选择 ---
            Picker("防抖模式", selection: Binding(
                get: { viewModel.config.stabilizationMode },
                set: { viewModel.setStabilizationMode($0) }
            )) {
                ForEach(ProcessingConfig.StabilizationMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // --- 防抖强度 ---
            if viewModel.config.stabilizationMode != .off {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("防抖强度")
                        Spacer()
                        Text("\(Int(viewModel.config.stabilizationStrength * 100))%")
                            .font(.caption.monospaced())
                            .foregroundColor(.orange)
                    }
                    Slider(value: Binding(
                        get: { viewModel.config.stabilizationStrength },
                        set: { viewModel.setStabilizationStrength($0) }
                    ), in: 0.0...1.0)
                    .tint(.orange)
                }
            }

            // --- 防抖启用开关 ---
            Toggle("启用地平线防抖", isOn: $viewModel.horizonStabilizer.isEnabled)
                .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 预览对比

    private var comparisonButton: some View {
        Button {
            Task { await viewModel.generatePreview() }
        } label: {
            Label("生成预览对比", systemImage: "rectangle.split.2x1")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.stage == .previewing || viewModel.stage == .processing)
    }

    // MARK: - 处理分区

    private var processSection: some View {
        VStack(spacing: 12) {
            // --- 处理按钮 ---
            if viewModel.stage != .processing {
                Button {
                    Task { await viewModel.startProcessing() }
                } label: {
                    Label("开始处理视频", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(viewModel.sourceVideoURL == nil)
            } else {
                // 处理中 — 显示进度
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.progress)
                        .tint(.orange)

                    HStack {
                        Text("处理中: \(Int(viewModel.progress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Spacer()

                        if viewModel.estimatedTimeRemaining > 0 {
                            Text("剩余约 \(Int(viewModel.estimatedTimeRemaining))秒")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // --- 完成提示 ---
            if viewModel.stage == .completed {
                Label("处理完成！视频已保存到相册", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 辅助组件

    private func sectionHeader(
        icon: String,
        title: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(color)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.red)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        ProcessingView(
            viewModel: ProcessingViewModel(),
            sourceVideo: LibraryViewModel.VideoItem(
                id: "test",
                asset: PHAsset(),
                creationDate: Date(),
                duration: 120
            )
        )
    }
}
