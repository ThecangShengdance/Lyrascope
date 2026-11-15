//
//  LyricsOverlayView.swift
//  Lyrascope
//
//  桌面歌词：一块可以拖到任何地方、永远浮在最上层的透明画布。
//

import SwiftUI

struct LyricsOverlayView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var hovering = false
    @State private var showControls = false

    private var accent: Theme.Accent { Theme.accent(settings.lyricsAccent) }

    var body: some View {
        let coordinator = model.lyrics
        let lines = visibleLines

        ZStack {
            if lines.isEmpty {
                placeholder
            } else {
                background

                VStack(alignment: settings.lyricsAlignment == .center ? .center : .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                    lineView(pair.element, isCurrent: pair.offset == currentOffset(in: lines))
                }
            }
                .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment == .center ? .center : .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .opacity(settings.lyricsOpacity)
            }

            if hovering {
                controls
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .onHover { value in
            withAnimation(.easeOut(duration: 0.2)) {
                hovering = value
                showControls = value
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.currentText)
        .background(Color.clear)
    }

    // MARK: 空状态

    /// 没有歌词可唱时，不画背景，只留一行很淡的提示——避免屏幕下方挂着一块黑框。
    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .medium))
            Text(placeholderText)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.textTertiary)
        .opacity(0.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .allowsHitTesting(false)
    }

    private var placeholderText: String {
        switch model.lyrics.status {
        case .loading: return "正在寻找歌词…"
        case .missing: return "这首歌暂时没有找到歌词"
        case .unsynced: return "歌词没有时间轴"
        default: return model.track == nil ? "播放音乐后，歌词会出现在这里" : "等待歌词…"
        }
    }

    // MARK: 内容

    private struct OverlayLine: Identifiable {
        let id: Int
        let index: Int
        let text: String
        let translation: String?
        let progress: Double
        let isCurrent: Bool
        let isSung: Bool
    }

    private var visibleLines: [OverlayLine] {
        let coordinator = model.lyrics
        guard let document = coordinator.document, !document.lines.isEmpty else { return [] }

        let index = coordinator.currentIndex
        guard index >= 0, index < document.lines.count else { return [] }

        let span = settings.lyricsFit.lineCount
        let lower = max(0, index - (span - 2))
        let upper = min(document.lines.count - 1, lower + span - 1)

        return (lower...upper).map { lineIndex in
            let line = document.lines[lineIndex]
            let isCurrent = lineIndex == index
            let progress = isCurrent ? coordinator.progress : (lineIndex < index ? 1 : 0)
            return OverlayLine(
                id: lineIndex,
                index: lineIndex,
                text: line.text,
                translation: settings.showTranslation ? line.translation : nil,
                progress: progress,
                isCurrent: isCurrent,
                isSung: lineIndex < index
            )
        }
    }

    private func currentOffset(in lines: [OverlayLine]) -> Int {
        lines.firstIndex(where: { $0.isCurrent }) ?? -1
    }

    @ViewBuilder
    private func lineView(_ line: OverlayLine, isCurrent: Bool) -> some View {
        VStack(alignment: settings.lyricsAlignment == .center ? .center : .leading, spacing: 2) {
            if isCurrent {
                KaraokeLine(
                    text: line.text,
                    progress: line.progress,
                    accent: accent.primary,
                    fontSize: settings.lyricsFontSize,
                    alignment: settings.lyricsAlignment
                )
                .shadow(color: .black.opacity(0.55), radius: 12, y: 1)
            } else {
                Text(line.text)
                    .font(.system(size: settings.lyricsFontSize * 0.72, weight: .semibold, design: .rounded))
                    .foregroundStyle(line.isSung ? Theme.textTertiary : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(settings.lyricsAlignment == .center ? .center : .leading)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 1)
            }

            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: settings.lyricsFontSize * 0.46, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment == .center ? .center : .leading)
    }

    @ViewBuilder
    private var background: some View {
        if settings.lyricsShowBackground {
            // 不用 Material：它跟随窗口外观取色，浅色壁纸上会整块发白
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.52))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.linearGradient(
                            colors: [Color.white.opacity(0.10), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
                .padding(6)
                .opacity(max(0.2, settings.lyricsOpacity))
        } else {
            Color.clear
        }
    }

    // MARK: 悬停控件

    private var controls: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "textformat.size.smaller", help: "缩小字号", accent: accent.primary) {
                settings.lyricsFontSize = max(16, settings.lyricsFontSize - 2)
            }
            IconButton(systemName: "textformat.size.larger", help: "放大字号", accent: accent.primary) {
                settings.lyricsFontSize = min(64, settings.lyricsFontSize + 2)
            }
            IconButton(
                systemName: settings.lyricsClickThrough ? "hand.raised.slash.fill" : "hand.raised.fill",
                help: "鼠标穿透（键盘不可拖拽）",
                isActive: settings.lyricsClickThrough,
                accent: accent.primary
            ) {
                settings.lyricsClickThrough.toggle()
            }
            IconButton(systemName: "xmark", help: "关闭桌面歌词", accent: accent.primary) {
                settings.showDesktopLyrics = false
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous).fill(Color.white.opacity(0.05))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }
}
