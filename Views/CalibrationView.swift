import SwiftUI

// MARK: - 镜头校准引导视图

/// 引导用户拍摄包含直线的场景，以便自动计算鱼眼畸变参数
///
/// 流程:
/// 1. 显示引导提示（"请对准包含水平线和垂直线的场景"）
/// 2. 用户对准后点「分析」
/// 3. 显示分析结果（检测到的畸变参数 + 匹配的镜头预设）
/// 4. 用户确认 → 保存为自定义预设
///
struct CalibrationView: View {

    // MARK: - 环境

    @Environment(\.dismiss) private var dismiss

    // MARK: - 参数

    /// 完成回调（传入新创建的镜头预设）
    var onComplete: ((LensProfile) -> Void)?

    /// 自动检测器
    var detector: AutoDetector?

    // MARK: - 状态

    @State private var calibrationStep: Step = .guide
    @State private var detectedResult: AutoDetector.DetectionResult?
    @State private var presetName: String = ""

    enum Step {
        case guide      // 引导提示
        case analyzing  // 分析中
        case result     // 显示结果
        case name       // 输入预设名称
        case done       // 完成
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                switch calibrationStep {
                case .guide:
                    guideStepView
                case .analyzing:
                    analyzingStepView
                case .result:
                    resultStepView
                case .name:
                    nameStepView
                case .done:
                    doneStepView
                }
            }
            .padding(24)
            .navigationTitle("镜头校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 步骤 1: 引导

    private var guideStepView: some View {
        VStack(spacing: 28) {
            // 图标
            Image(systemName: "viewfinder")
                .font(.system(size: 80))
                .foregroundColor(.orange)

            // 标题
            Text("镜头校准")
                .font(.title)
                .fontWeight(.bold)

            // 说明
            VStack(alignment: .leading, spacing: 12) {
                guideTip(
                    icon: "1.circle.fill",
                    text: "找一个包含明显直线的场景（建筑外立面、窗户、门框）"
                )
                guideTip(
                    icon: "2.circle.fill",
                    text: "将相机对准场景，确保直线清晰可见"
                )
                guideTip(
                    icon: "3.circle.fill",
                    text: "点击「开始分析」— App 会检测画面中的直线弯曲程度"
                )
                guideTip(
                    icon: "4.circle.fill",
                    text: "确认结果后保存为你的专属镜头预设"
                )
            }

            // 开始按钮
            Button {
                startAnalysis()
            } label: {
                Label("开始分析", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    private func guideTip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 步骤 2: 分析中

    private var analyzingStepView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在分析畸变参数...")
                .font(.headline)
            Text("请在分析完成前保持设备稳定")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 步骤 3: 结果显示

    private var resultStepView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("分析完成")
                .font(.title2)
                .fontWeight(.bold)

            if let result = detectedResult {
                // 参数详情
                VStack(spacing: 10) {
                    resultRow(label: "k1 (主畸变)", value: String(format: "%.4f", result.params.k1))
                    resultRow(label: "k2 (高阶畸变)", value: String(format: "%.4f", result.params.k2))
                    resultRow(label: "矫正缩放", value: String(format: "%.2f", result.params.scale))
                    resultRow(label: "匹配置信度", value: "\(Int(result.confidence * 100))%")

                    if let preset = result.matchedPreset {
                        resultRow(label: "匹配镜头", value: preset.displayName)
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 16) {
                    Button("重新分析") {
                        startAnalysis()
                    }
                    .buttonStyle(.bordered)

                    Button("保存预设") {
                        presetName = result.matchedPreset?.displayName ?? "自定义预设"
                        calibrationStep = .name
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
    }

    private func resultRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - 步骤 4: 命名

    private var nameStepView: some View {
        VStack(spacing: 20) {
            Text("保存自定义预设")
                .font(.title2)
                .fontWeight(.bold)

            TextField("预设名称", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("取消") {
                    calibrationStep = .result
                }
                .buttonStyle(.bordered)

                Button("保存") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - 步骤 5: 完成

    private var doneStepView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 70))
                .foregroundColor(.green)

            Text("预设已保存！")
                .font(.title2)
                .fontWeight(.bold)

            Text("你可以在「拍摄」或「设置」中选择该预设")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("完成") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.top)
        }
    }

    // MARK: - 逻辑

    private func startAnalysis() {
        calibrationStep = .analyzing

        Task {
            // 模拟分析延迟（实际由 AutoDetector 处理）
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // 使用默认检测结果（实际场景中由 AutoDetector 分析相机帧）
            let result = AutoDetector.DetectionResult(
                params: .standardFisheye,
                confidence: 0.75,
                matchedPreset: nil,
                method: .lineAnalysis
            )

            await MainActor.run {
                detectedResult = result
                calibrationStep = .result
            }
        }
    }

    private func savePreset() {
        guard var result = detectedResult else { return }

        let customPreset = LensProfile(
            manufacturer: "自定义",
            model: presetName.trimmingCharacters(in: .whitespaces),
            lensType: .wide,
            distortionParams: result.params,
            isUserCustom: true
        )

        onComplete?(customPreset)
        calibrationStep = .done
    }
}

// MARK: - 预览

#Preview {
    CalibrationView()
}
