import SwiftUI

// MARK: - App 入口

/// FishEye Stabilizer — 鱼眼矫正 + 地平线防抖视频处理 App
///
/// 核心功能:
/// 1. 实时拍摄 — 相机采集时实时进行鱼眼矫正和地平线防抖
/// 2. 后期处理 — 对相册中的视频进行离线矫正和防抖
/// 3. 自动检测 — 自动分析视频中的鱼眼畸变参数
/// 4. 镜头预设 — 内置 20+ 常见运动相机镜头参数
///
/// 技术栈:
/// - UI: SwiftUI + Swift 5.9
/// - 相机: AVFoundation
/// - 视频处理: Metal + Metal Shading Language
/// - 运动数据: Core Motion
/// - 图像分析: Vision + Core Image
/// - 最低版本: iOS 17.0
///
@main
struct FishEyeStabilizerApp: App {

    // MARK: - 场景

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(.dark) // 深色主题更适合视频处理预览
        }
    }
}
