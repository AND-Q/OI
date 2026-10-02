import AppKit
import SwiftUI

/// Raycast 风格的右下角悬浮毛玻璃操作卡片。
@MainActor
struct LauncherActionSheetView: View {
    let result: SearchResult
    let actions: [ResultMenuAction]
    let selectedIndex: Int
    let iconProvider: any ApplicationIconProviding
    let onSelect: (ResultMenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            actionsList
        }
        .frame(width: 250)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            // 消费卡片内非按钮区域（标题栏、分割线等）的点击，防止击穿到外部关闭遮罩。
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            headerIcon
            Text(result.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("操作")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.8))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 11)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let symbolName = result.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        } else if let url = result.url {
            Image(nsImage: iconProvider.icon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        }
    }

    private var divider: some View {
        Color.primary.opacity(0.08)
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    private var actionsList: some View {
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                let isSelected = index == selectedIndex
                actionRow(action, isSelected: isSelected)
            }
        }
        .padding(.horizontal, 5)
        .padding(.bottom, 6)
    }

    private func actionRow(_ action: ResultMenuAction, isSelected: Bool) -> some View {
        Button {
            onSelect(action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 16, height: 16)

                Text(action.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    ForEach(action.shortcutKeys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.06))
                            )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
