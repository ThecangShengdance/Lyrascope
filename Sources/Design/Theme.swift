//
//  Theme.swift
//  Lyrascope
//
//  一套极简的深色视觉语言：玻璃、细描边、单色排版 + 一处克制的渐变点缀。
//

import SwiftUI

enum Theme {

    // MARK: 基础色

    static let canvas = Color(red: 0.027, green: 0.031, blue: 0.043)
    static let panel = Color.white.opacity(0.055)
    static let panelStrong = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.18)

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.56)
    static let textTertiary = Color.white.opacity(0.34)

    // MARK: 强调色

    struct Accent {
        var primary: Color
        var secondary: Color
    }

    static func accent(_ style: AccentStyle) -> Accent {
        switch style {
        case .aurora:
            return Accent(
                primary: Color(red: 0.32, green: 0.93, blue: 0.84),
                secondary: Color(red: 0.62, green: 0.48, blue: 1.00)
            )
        case .gold:
            return Accent(
                primary: Color(red: 1.00, green: 0.80, blue: 0.36),
                secondary: Color(red: 1.00, green: 0.56, blue: 0.22)
            )
        case .ice:
            return Accent(
                primary: Color(red: 0.58, green: 0.82, blue: 1.00),
                secondary: Color(red: 0.34, green: 0.55, blue: 1.00)
            )
        case .mono:
            return Accent(
                primary: Color.white.opacity(0.92),
                secondary: Color.white.opacity(0.55)
            )
        }
    }

    static func gradient(_ style: AccentStyle) -> LinearGradient {
        let accent = Self.accent(style)
        return LinearGradient(
            colors: [accent.primary, accent.secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: 字体

    static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoLarge = Font.system(size: 26, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold, design: .rounded)
}

// MARK: - 玻璃面板

struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 18
    var emphasized: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(emphasized ? Theme.panelStrong : Theme.panel)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 图标按钮

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var isActive: Bool = false
    var accent: Color = .white
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? accent : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(isActive ? accent.opacity(0.16) : (hovering ? Color.white.opacity(0.10) : Color.clear))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 胶囊按钮

struct PillButton: View {
    let title: String
    var systemName: String?
    var prominent: Bool = false
    var accent: Color = Theme.accent(.aurora).primary
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(prominent ? accent : Color.white.opacity(hovering ? 0.14 : 0.08))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0 : 0.10), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 小型分段控件

struct SegmentedBar<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var accent: Color = Theme.accent(.aurora).primary

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let active = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            Capsule(style: .continuous)
                                .fill(active ? accent : Color.clear)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous).fill(Color.white.opacity(0.05))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }
}

// MARK: - 设置里的行

struct SettingRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 9)
    }
}

struct SettingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
    }
}

// MARK: - 卡拉 OK 歌词

struct KaraokeLine: View {
    let text: String
    let progress: Double
    let accent: Color
    let fontSize: CGFloat
    var alignment: LyricsAlignment = .center
    var forceDim: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(forceDim ? Theme.textSecondary : Color.white.opacity(0.30))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Text(text)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .frame(width: proxy.size.width, alignment: alignment == .center ? .center : .leading)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(0, proxy.size.width * progress))
                        }
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: accent.opacity(0.18), radius: 12)
            .animation(.linear(duration: 0.08), value: progress)
    }
}
