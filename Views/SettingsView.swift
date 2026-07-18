import SwiftUI
@preconcurrency import AVFoundation

// MARK: - 设置视图

/// App 设置页面
///
/// 分区:
/// - 导出设置（默认分辨率、码率、帧率）
/// - 录制设置
/// - 关于
///
struct SettingsView: View {

    @ObservedObject var cameraVM: CameraViewModel

    // MARK: - 状态

    @State private var showCalibration = false
    @AppStorage("outputResolution") private var outputResolution = ProcessingConfig.OutputResolution.matchInput.rawValue
    @AppStorage("outputBitrate") private var outputBitrate: Double = 50.0
    @AppStorage("outputFrameRate") private var outputFrameRate = 60

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // --- 导出设置 ---
                Section {
                    Picker("默认分辨率", selection: $outputResolution) {
                        ForEach(ProcessingConfig.OutputResolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res.rawValue)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("默认码率")
                            Spacer()
                            Text("\(Int(outputBitrate)) Mbps")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $outputBitrate, in: 10...100, step: 5)
                            .tint(.orange)
                    }

                    Stepper("默认帧率: \(outputFrameRate)fps",
                            value: $outputFrameRate,
                            in: 24...60,
                            step: 1)
                } header: {
                    Label("导出设置", systemImage: "gearshape.2")
                }

                // 录制设置在后续版本开放

                // --- 镜头校准 ---
                Section {
                    Button {
                        showCalibration = true
                    } label: {
                        Label("镜头校准向导", systemImage: "viewfinder")
                    }

                    // 用户自定义预设数量
                    Label(
                        "用户预设: \(cameraVM.lensPresetService.userPresets.count) 个",
                        systemImage: "person.crop.rectangle.stack"
                    )
                } header: {
                    Label("镜头管理", systemImage: "camera.lens.fill")
                }

                // --- 关于 ---
                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/fisheye-stabilizer")!) {
                        Label("项目主页", systemImage: "link")
                    }
                } header: {
                    Label("关于", systemImage: "info.circle")
                }

                // --- 免责声明 ---
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("处理提示")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("""
                        • 鱼眼矫正会损失画面边缘约 5-30%，畸变越严重损失越大
                        • 地平线防抖会额外裁剪约 8-15% 的像素
                        • 4K@60fps 实时处理建议使用 iPhone 13 或更新机型
                        • 后期处理大文件时请确保设备有足够的存储空间
                        • 镜头预设参数为近似值，实际效果可能因个体差异略有不同
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("提示", systemImage: "lightbulb")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showCalibration) {
                CalibrationView(
                    onComplete: { preset in
                        cameraVM.lensPresetService.addUserPreset(preset)
                    },
                    detector: AutoDetector(
                        presetService: cameraVM.lensPresetService
                    )
                )
            }
        }
    }
}

// Preview omitted
