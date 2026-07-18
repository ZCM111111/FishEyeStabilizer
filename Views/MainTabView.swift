import SwiftUI

// MARK: - 主 Tab 视图

/// App 主界面，包含三个 Tab:
/// 1. 拍摄 — 实时预览 + 录制
/// 2. 相册 — 选择已有视频进行后期处理
/// 3. 设置 — 镜头预设管理 + 导出参数配置
///
struct MainTabView: View {

    // MARK: - 状态

    @StateObject private var cameraVM = CameraViewModel()
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var processingVM = ProcessingViewModel()

    @State private var selectedTab: Tab = .record

    // MARK: - Tab 枚举

    enum Tab: String, CaseIterable {
        case record = "拍摄"
        case library = "相册"
        case settings = "设置"

        var icon: String {
            switch self {
            case .record:   return "camera.fill"
            case .library:  return "photo.on.rectangle"
            case .settings: return "gearshape.fill"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        TabView(selection: $selectedTab) {

            // --- 拍摄 Tab ---
            RecordView(viewModel: cameraVM)
                .tabItem {
                    Label(Tab.record.rawValue, systemImage: Tab.record.icon)
                }
                .tag(Tab.record)

            // --- 相册 Tab ---
            LibraryView(
                libraryVM: libraryVM,
                processingVM: processingVM
            )
                .tabItem {
                    Label(Tab.library.rawValue, systemImage: Tab.library.icon)
                }
                .tag(Tab.library)

            // --- 设置 Tab ---
            SettingsView(cameraVM: cameraVM)
                .tabItem {
                    Label(Tab.settings.rawValue, systemImage: Tab.settings.icon)
                }
                .tag(Tab.settings)
        }
        .tint(.orange) // App 主题色
        .onAppear {
            // 启动相机预览（仅在拍摄 Tab 时）
            if selectedTab == .record {
                cameraVM.startCamera()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .record {
                cameraVM.startCamera()
            } else {
                cameraVM.stopCamera()
            }
        }
    }
}

// MARK: - 预览

#Preview {
    MainTabView()
}
