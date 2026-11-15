//
//  MenuBarPanelView.swift
//  Lyrascope
//
//  菜单栏弹出面板：小号的同一套体验。
//

import SwiftUI

struct MenuBarPanelView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    private var accent: Theme.Accent { Theme.accent(settings.lyricsAccent) }

    var body: some View {
        VStack(spacing: 0) {
            header
            visualizer
            trackRow
            lyricsBlock
            quickToggles
            footer
        }
        .frame(width: 340)
        .background(Theme.canvas)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.captureState.isRunning ? accent.primary : Color.orange)
                .frame(width: 6, height: 6)
                .shadow(color: accent.primary.opacity(0.6), radius: 4)

            Text("Lyrascope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(model.statusText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)

            Spacer()

            Button {
                model.toggleVisualMode()
            } label: {
                Image(systemName: settings.visualMode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(settings.visualMode.subtitle)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: 画面

    private var visualizer: some View {
        ZStack(alignment: .bottomLeading) {
            VisualizerView(engine: model.engine, preferredFPS: 24)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }

            HStack(spacing: 6) {
                Text(settings.visualMode.title)
                Text("·")
                Text(String(format: "%.0f LUFS", model.frame.loudness))
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .padding(.horizontal, 14)
    }

    // MARK: 曲目

    private var trackRow: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = model.track?.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.gradient(settings.lyricsAccent)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.track?.title ?? "还没有播放音乐")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(model.track?.artist ?? "打开 Apple Music 试试")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let track = model.track, track.duration > 0 {
                Text(timeLabel(model.nowPlaying.estimatedPosition()) + " / " + timeLabel(track.duration))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // MARK: 歌词

    private var lyricsBlock: some View {
        VStack(spacing: 4) {
            if model.lyrics.currentText.isEmpty {
                Text(emptyLyricLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                KaraokeLine(
                    text: model.lyrics.currentText,
                    progress: model.lyrics.progress,
                    accent: accent.primary,
                    fontSize: 15,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if settings.showTranslation, !model.lyrics.translationText.isEmpty {
                    Text(model.lyrics.translationText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !model.lyrics.nextText.isEmpty {
                    Text(model.lyrics.nextText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 52, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .overlay(alignment: .bottom) {
            lyricProgressBar
                .padding(.horizontal, 14)
                .padding(.bottom, 1)
        }
    }

    /// 当前这一行歌词的进度（跟桌面歌词的逐字高亮同一个 progress）。
    private var lyricProgressBar: some View {
        GeometryReader { geo in
            let progress = CGFloat(min(max(model.lyrics.progress, 0), 1))
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(
                        colors: [accent.primary, accent.secondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(2, width * progress))
                    .shadow(color: accent.primary.opacity(0.55), radius: 3)
                    .opacity(model.lyrics.currentText.isEmpty ? 0 : 1)
            }
        }
        .frame(height: 2.5)
        .opacity(model.lyrics.currentText.isEmpty ? 0 : 1)
        .animation(.linear(duration: 0.12), value: model.lyrics.progress)
    }

    private var emptyLyricLabel: String {
        switch model.lyrics.status {
        case .loading: return "正在寻找歌词…"
        case .missing: return "这首歌暂时没有找到歌词"
        case .unsynced: return "歌词没有时间轴"
        default: return "播放时歌词会出现在这里"
        }
    }

    // MARK: 快捷开关

    private var quickToggles: some View {
        HStack(spacing: 8) {
            toggleChip("桌面歌词", systemName: "text.bubble", isOn: settings.showDesktopLyrics) {
                settings.showDesktopLyrics.toggle()
            }
            toggleChip("置顶", systemName: "pin", isOn: settings.alwaysOnTop) {
                settings.alwaysOnTop.toggle()
            }
            toggleChip("图标频谱", systemName: "waveform", isOn: settings.menuBarShowSpectrum) {
                settings.menuBarShowSpectrum.toggle()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func toggleChip(_ title: String, systemName: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isOn ? accent.primary : Theme.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background {
                Capsule(style: .continuous)
                    .fill(isOn ? accent.primary.opacity(0.14) : Color.white.opacity(0.05))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? accent.primary.opacity(0.35) : Theme.stroke, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            PillButton(title: "主窗口", systemName: "macwindow", accent: accent.primary) {
                WindowManager.shared.showMainWindow()
                WindowManager.shared.togglePopover()
            }
            PillButton(title: "设置", systemName: "slider.horizontal.3", accent: accent.primary) {
                WindowManager.shared.showSettings()
                WindowManager.shared.togglePopover()
            }
            Spacer()
            IconButton(systemName: "power", help: "退出 Lyrascope") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
