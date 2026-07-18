import SwiftUI
@preconcurrency import MetalKit

// MARK: - 拍摄视图

/// 实时预览 + 录制界面
///
/// 布局:
/// - 全屏 Metal 渲染预览（显示鱼眼矫正 + 地平线防抖后的画面）
/// - 顶部: 状态栏（录制时长、防抖模式指示器）
/// - 底部: 录制按钮 + 参数快速调节
/// - 浮层: 镜头预设选择器、校准入口
///
struct RecordView: View {

    @ObservedObject var viewModel: CameraViewModel

    // MARK: - 状态

    @State private var showPresetSheet = false
    @State private var showFineTunePanel = false
    @State private var k1Slider: Float = 0
    @State private var k2Slider: Float = 0
    @State private var scaleSlider: Float = 1.0

    // MARK: - Body

    var body: some View {
        ZStack {
            // --- 背景 ---
            Color.black.ignoresSafeArea()

            // --- 相机预览 ---
            MetalPreviewView(renderer: viewModel.renderer)
                .ignoresSafeArea()

            // --- 叠加层 ---
            VStack {
                // 顶部状态栏
                topStatusBar
                Spacer()
                // 底部控制栏
                bottomControls
            }

            // --- 浮层 ---
            if showFineTunePanel {
                fineTuneOverlay
            }
        }
        .onAppear {
            viewModel.startCamera()
        }
        .onDisappear {
            viewModel.stopCamera()
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetPickerView(
                presets: viewModel.lensPresetService.allPresets,
                selectedPreset: viewModel.fisheyeCorrector.selectedPreset,
                onSelect: { viewModel.selectPreset($0) }
            )
        }
    }

    // MARK: - 顶部状态栏

    private var topStatusBar: some View {
        HStack {
            // --- 录制指示器 ---
            if viewModel.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .blinking() // 录制时闪烁
                    Text(formatDuration(viewModel.recordingDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }

            Spacer()

            // --- 防抖模式指示器 ---
            stabilizationBadge
        }
        .padding(.horizontal, 20)
        .padding(.top, 50)
    }

    /// 防抖模式标签
    private var stabilizationBadge: some View {
        let mode = viewModel.processingConfig.stabilizationMode

        return HStack(spacing: 4) {
            Image(systemName: iconForStabilizationMode(mode))
                .font(.caption)
            Text(mode.rawValue)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(mode == .horizonLevel ? .orange : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .onTapGesture {
            cycleStabilizationMode()
        }
    }

    // MARK: - 底部控制栏

    private var bottomControls: some View {
        VStack(spacing: 20) {
            // --- 快速操作按钮行 ---
            HStack(spacing: 30) {
                // 镜头预设
                quickButton(
                    icon: "camera.lens.fill",
                    title: "镜头",
                    action: { showPresetSheet = true }
                )

                // 手动微调
                quickButton(
                    icon: "slider.horizontal.3",
                    title: "微调",
                    action: { withAnimation { showFineTunePanel.toggle() } }
                )

                // 校准
                quickButton(
                    icon: "viewfinder",
                    title: "校准",
                    action: { viewModel.showCalibration = true }
                )

                // 切换防抖
                quickButton(
                    icon: "gyroscope",
                    title: "防抖",
                    action: { cycleStabilizationMode() },
                    isActive: viewModel.processingConfig.stabilizationMode != .off
                )
            }

            // --- 录制按钮 ---
            recordButton
        }
        .padding(.bottom, 40)
    }

    /// 录制按钮
    private var recordButton: some View {
        Button {
            if viewModel.isRecording {
                viewModel.stopRecording()
            } else {
                viewModel.startRecording()
            }
        } label: {
            ZStack {
                // 外圈
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 80, height: 80)

                // 内部（录制时缩小为方形）
                if viewModel.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 64, height: 64)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 微调浮层

    private var fineTuneOverlay: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                Text("畸变参数微调")
                    .font(.headline)
                    .foregroundColor(.white)

                // k1 滑块
                sliderRow(
                    label: "k1 (桶形矫正)",
                    value: $k1Slider,
                    range: -0.6...0.0,
                    format: "%.3f"
                )
                .onChange(of: k1Slider) { _, new in
                    viewModel.fisheyeCorrector.fineTune(deltaK1: new - k1Slider)
                }

                // k2 滑块
                sliderRow(
                    label: "k2 (高阶矫正)",
                    value: $k2Slider,
                    range: 0.0...0.3,
                    format: "%.3f"
                )
                .onChange(of: k2Slider) { _, new in
                    viewModel.fisheyeCorrector.fineTune(deltaK2: new - k2Slider)
                }

                // 缩放滑块
                sliderRow(
                    label: "缩放",
                    value: $scaleSlider,
                    range: 0.8...1.5,
                    format: "%.2f"
                )
                .onChange(of: scaleSlider) { _, new in
                    viewModel.fisheyeCorrector.fineTune(deltaScale: new - scaleSlider)
                }

                Button("关闭") {
                    withAnimation { showFineTunePanel = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }

    // MARK: - 辅助方法

    private func quickButton(
        icon: String,
        title: String,
        action: @escaping () -> Void,
        isActive: Bool = false
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .foregroundColor(isActive ? .orange : .white)
            .frame(width: 60, height: 50)
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospaced())
                    .foregroundColor(.orange)
            }
            Slider(value: value, in: range)
                .tint(.orange)
        }
    }

    private func cycleStabilizationMode() {
        let modes = ProcessingConfig.StabilizationMode.allCases
        guard let currentIndex = modes.firstIndex(
            of: viewModel.processingConfig.stabilizationMode
        ) else { return }

        let nextIndex = (currentIndex + 1) % modes.count
        viewModel.setStabilizationMode(modes[nextIndex])
    }

    private func iconForStabilizationMode(
        _ mode: ProcessingConfig.StabilizationMode
    ) -> String {
        switch mode {
        case .off:          return "slash.circle"
        case .standard:     return "gyroscope"
        case .horizonLevel: return "level"
        case .fullLock:     return "lock.rotation"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Metal 预览视图 (MTKView 的 SwiftUI 封装)

/// 将 MetalKit 的 MTKView 封装为 SwiftUI 视图
/// 显示实时相机预览
struct MetalPreviewView: UIViewRepresentable {
    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true // 手动控制渲染时机
        view.enableSetNeedsDisplay = true
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // MetalRenderer 通过其 render(into:) 方法写入 MTKView
    }
}

// MARK: - 闪烁修饰符

private struct BlinkingModifier: ViewModifier {
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                ) {
                    opacity = 0.3
                }
            }
    }
}

private extension View {
    func blinking() -> some View {
        modifier(BlinkingModifier())
    }
}

// MARK: - 预览

#Preview {
    RecordView(viewModel: CameraViewModel())
}
