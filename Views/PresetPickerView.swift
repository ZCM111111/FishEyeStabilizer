import SwiftUI

// MARK: - 镜头预设选择器

/// 以列表形式展示所有可用镜头预设，支持搜索和分类
///
/// 分组:
/// - 大疆 (DJI)
/// - GoPro
/// - Insta360
/// - SONY
/// - 通用预设
/// - 用户自定义
///
struct PresetPickerView: View {

    @Environment(\.dismiss) private var dismiss

    /// 所有可用预设
    let presets: [LensProfile]

    /// 当前选中的预设
    var selectedPreset: LensProfile?

    /// 选中回调
    var onSelect: (LensProfile) -> Void

    // MARK: - 状态

    @State private var searchText = ""
    @State private var selectedManufacturer: String? = nil

    // MARK: - 分组

    /// 按制造商分组
    private var groupedPresets: [(manufacturer: String, presets: [LensProfile])] {
        let filtered = searchText.isEmpty
            ? presets
            : presets.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }

        let grouped = Dictionary(grouping: filtered) { $0.manufacturer }
        return grouped
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                // 用户自定义排在最后
                if a.0 == "自定义" { return false }
                if b.0 == "自定义" { return true }
                // 通用排在倒数第二
                if a.0 == "通用" { return false }
                if b.0 == "通用" { return true }
                return a.0 < b.0
            }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedPresets, id: \.manufacturer) { group in
                    Section(group.manufacturer) {
                        ForEach(group.presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索镜头型号")
            .navigationTitle("选择镜头预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 预设行

    private func presetRow(_ preset: LensProfile) -> some View {
        let isSelected = preset.id == selectedPreset?.id

        return Button {
            onSelect(preset)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.model)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    HStack(spacing: 6) {
                        Text(preset.manufacturer)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("·")
                            .foregroundColor(.secondary)

                        Text(preset.lensType.rawValue)
                            .font(.caption)
                            .foregroundColor(.orange)

                        Text("·")
                            .foregroundColor(.secondary)

                        Text(preset.lensType.approximateFOV)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.orange)
                        .font(.title3)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 预览

#Preview {
    PresetPickerView(
        presets: LensPresetService.hardcodedPresets,
        selectedPreset: nil,
        onSelect: { _ in }
    )
}
