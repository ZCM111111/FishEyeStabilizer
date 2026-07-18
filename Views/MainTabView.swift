import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .record

    enum Tab: String, CaseIterable {
        case record = "拍摄", library = "相册", settings = "设置"
        var icon: String {
            switch self {
            case .record: "camera.fill"
            case .library: "photo.on.rectangle"
            case .settings: "gearshape.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TabScreen(tab: .record, selectedTab: $selectedTab)
                .tabItem { Label(Tab.record.rawValue, systemImage: Tab.record.icon) }
                .tag(Tab.record)

            TabScreen(tab: .library, selectedTab: $selectedTab)
                .tabItem { Label(Tab.library.rawValue, systemImage: Tab.library.icon) }
                .tag(Tab.library)

            TabScreen(tab: .settings, selectedTab: $selectedTab)
                .tabItem { Label(Tab.settings.rawValue, systemImage: Tab.settings.icon) }
                .tag(Tab.settings)
        }
        .tint(.orange)
    }
}

// MARK: - 每个 Tab 独立创建 ViewModel

private struct TabScreen: View {
    let tab: MainTabView.Tab
    @Binding var selectedTab: MainTabView.Tab

    @State private var appeared = false

    var body: some View {
        ZStack {
            if appeared {
                tabContent
            } else {
                Color.black
            }
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .record:
            RecordTab()
        case .library:
            LibraryTab()
        case .settings:
            SettingsTab()
        }
    }
}

// MARK: - 子页面（各自独立持有 ViewModel）

private struct RecordTab: View {
    @StateObject private var vm = CameraViewModel()
    var body: some View {
        RecordView(viewModel: vm)
            .onAppear { vm.startCamera() }
            .onDisappear { vm.stopCamera() }
    }
}

private struct LibraryTab: View {
    @StateObject private var libVM = LibraryViewModel()
    @StateObject private var procVM = ProcessingViewModel()
    var body: some View {
        LibraryView(libraryVM: libVM, processingVM: procVM)
    }
}

/// 设置 Tab — 仅创建所需的最小依赖（LensPresetService），
/// 不再创建完整的 CameraViewModel（避免重复的 AVCaptureSession、CMMotionManager、Metal 设备等）
private struct SettingsTab: View {
    @StateObject private var lensPresetService = LensPresetService()

    var body: some View {
        SettingsView(lensPresetService: lensPresetService)
    }
}
