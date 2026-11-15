//
//  RootView.swift
//  Lyrascope
//
//  主窗口：可视化铺满整块画布，控件与歌词浮在上面，静止一会儿就自动淡出。
//

import AppKit
import SwiftUI

struct RootView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hoveringChrome = false
    @State private var isHoveringWindow = true

    private var accent: Theme.Accent { Theme.accent(settings.lyricsAccent) }

    var body: some View {
        ZStack {
            VisualizerView(engine: model.engine, preferredFPS: model.effectiveFPS)
                .ignoresSafeArea()

            if settings.visualMode.isAnalytic {
                StudioHUD(frame: model.frame, accent: accent, track: model.track)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                TopBar(
                    accent: accent,
                    chromeVisible: chromeVisible,
                    onHover: { hoveringChrome = $0 }
                )
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)

                Spacer(minLength: 0)

                if shouldShowIdle {
                    IdleHint(accent: accent)
                        .padding(.bottom, 40)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if !settings.visualMode.isAnalytic {
                    LyricsBand(fontSize: 26, accent: accent)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 26)
                        .opacity(chromeVisible || settings.showChrome ? 1 : 0)
                }

                ProgressLine(accent: accent, chromeVisible: chromeVisible)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                    .opacity(chromeVisible ? 1 : 0)
            }
        }
        .background(Color.black)
        .translationHost()
        .ignoresSafeArea()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHoveringWindow = true
                revealChrome()
            case .ended:
                isHoveringWindow = false
                scheduleHide()
            }
        }
        .onChange(of: settings.visualMode) { _, _ in revealChrome() }
        .animation(.easeOut(duration: 0.35), value: shouldShowIdle)
        .animation(.easeInOut(duration: 0.45), value: chromeVisible)
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environmentObject(settings)
                .environmentObject(model.translator)
                .preferredColorScheme(.dark)
        }
        .background(WindowAccessor { window in
            window?.appearance = NSAppearance(named: .darkAqua)
        })
    }

    private var shouldShowIdle: Bool {
        if case .failed = model.captureState { return true }
        guard model.captureState.isRunning else { return true }
        // 有曲目信息时不要催用户“按下播放”，那通常是 Apple Music 那边的播放状态还没同步。
        return model.isSilent && model.track == nil && model.lyrics.currentText.isEmpty
    }

    private func revealChrome() {
        guard settings.showChrome else { return }
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard settings.showChrome, !hoveringChrome else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, !hoveringChrome, !isHoveringWindow else { return }
            withAnimation(.easeInOut(duration: 0.5)) { chromeVisible = false }
        }
    }
}

// MARK: - 顶栏

private struct TopBar: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    let accent: Theme.Accent
    let chromeVisible: Bool
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            TrackBadge(track: model.track, accent: accent)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ModeSwitch(accent: accent)

                Divider().frame(height: 18).overlay(Theme.stroke)

                IconButton(
                    systemName: "paintpalette",
                    help: "切换强调色（\(settings.lyricsAccent.title)）",
                    accent: accent.primary
                ) { model.cycleAccent() }

                IconButton(
                    systemName: settings.showDesktopLyrics ? "text.bubble.fill" : "text.bubble",
                    help: "桌面歌词",
                    isActive: settings.showDesktopLyrics,
                    accent: accent.primary
                ) { model.toggleLyrics() }

                IconButton(
                    systemName: settings.alwaysOnTop ? "pin.fill" : "pin",
                    help: "窗口置顶",
                    isActive: settings.alwaysOnTop,
                    accent: accent.primary
                ) {
                    settings.alwaysOnTop.toggle()
                }

                IconButton(
                    systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: "全屏（⌃⌘F）",
                    accent: accent.primary
                ) { model.toggleFullScreen() }

                IconButton(systemName: "slider.horizontal.3", help: "设置（⌘,）", accent: accent.primary) {
                    WindowManager.shared.showSettings()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(Color.white.opacity(0.04))
            }
            .overlay {
                Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .onHover(perform: onHover)
        }
    }
}

private struct ModeSwitch: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    let accent: Theme.Accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VisualMode.allCases) { mode in
                let active = settings.visualMode == mode
                Button {
                    withAnimation(.snappy(duration: 0.3)) { settings.visualMode = mode }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? Color.black.opacity(0.82) : Theme.textSecondary)
                        .frame(width: 30, height: 26)
                        .background {
                            Capsule(style: .continuous)
                                .fill(active ? AnyShapeStyle(Theme.gradient(settings.lyricsAccent)) : AnyShapeStyle(Color.clear))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(mode.title) · \(mode.subtitle)")
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

private struct TrackBadge: View {

    let track: NowPlayingTrack?
    let accent: Theme.Accent

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Lyrascope")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(track.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? "等待 Apple Music 播放")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous).fill(Color.white.opacity(0.035))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = track?.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.gradient(.aurora).opacity(0.55))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
    }
}

// MARK: - 底部歌词条

struct LyricsBand: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    var fontSize: CGFloat = 26
    var accent: Theme.Accent

    var body: some View {
        let coordinator = model.lyrics
        let current = coordinator.currentText
        let next = coordinator.nextText

        VStack(spacing: 10) {
            if !current.isEmpty {
                KaraokeLine(
                    text: current,
                    progress: coordinator.progress,
                    accent: accent.primary,
                    fontSize: fontSize,
                    alignment: settings.lyricsAlignment,
                    forceDim: false
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 2)

                if coordinator.document?.isEstimated == true {
                    Text("时间轴按曲长估算")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary.opacity(0.75))
                }

                if settings.showTranslation, !coordinator.translationText.isEmpty {
                    Text(coordinator.translationText)
                        .font(.system(size: fontSize * 0.55, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else if !next.isEmpty {
                    Text(next)
                        .font(.system(size: fontSize * 0.58, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            } else {
                Text(emptyLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.35), value: current)
    }

    private var emptyLabel: String {
        switch model.lyrics.status {
        case .loading: return "正在寻找歌词…"
        case .missing: return "这首歌暂时没有找到歌词"
        case .unsynced: return "找到了歌词，但没有时间轴"
        case .idle: return "歌词会在音乐播放时出现"
        default: return ""
        }
    }
}

// MARK: - 进度线

private struct ProgressLine: View {

    @EnvironmentObject private var model: AppModel
    let accent: Theme.Accent
    let chromeVisible: Bool

    var body: some View {
        let track = model.track
        let duration = max(track?.duration ?? 0, 0.001)
        let position = min(model.nowPlaying.estimatedPosition(), duration)
        let progress = track == nil ? 0 : position / duration

        VStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(height: 2)
                    Capsule()
                        .fill(Theme.gradient(.aurora))
                        .frame(width: max(0, proxy.size.width * progress), height: 2)
                }
            }
            .frame(height: 2)

            HStack {
                Text(format(position))
                Spacer()
                Text(track.map { $0.subtitle } ?? " ")
                Spacer()
                Text(format(track?.duration ?? 0))
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textTertiary)
        }
        .opacity(chromeVisible ? 1 : 0.25)
        .animation(.linear(duration: 0.3), value: progress)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 空闲提示

private struct IdleHint: View {

    @EnvironmentObject private var model: AppModel
    let accent: Theme.Accent

    var body: some View {
        VStack(spacing: 14) {
            if case let .failed(message) = model.captureState {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text("没能听到系统音频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                PillButton(title: "重试", systemName: "arrow.clockwise", accent: accent.primary) {
                    model.retryAudio()
                }
                .padding(.top, 4)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text("在 Apple Music 里按下播放")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Lyrascope 会实时读取系统声音，画出画面，并寻找歌词。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                if model.needsAudioPermission {
                    PillButton(title: "授予录音权限", systemName: "lock.open", accent: accent.primary) {
                        model.openPrivacySettings()
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
        }
    }
}

// MARK: - 制作人 HUD

struct StudioHUD: View {

    let frame: AudioFrame
    let accent: Theme.Accent
    let track: NowPlayingTrack?

    var body: some View {
        VStack {
            HStack {
                Text("ANALYZER")
                    .font(Theme.monoSmall)
                    .tracking(2.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(Int(frame.sampleRate / 1000)) kHz · FFT 4096")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 26)
            .padding(.top, 84)

            Spacer()

            HStack(alignment: .bottom) {
                metrics
                Spacer()
                bandLegend
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 96)
        }
        .allowsHitTesting(false)
    }

    private var metrics: some View {
        HStack(spacing: 18) {
            metric("LUFS", String(format: "%5.1f", frame.loudness), color: lufsColor)
            metric("PEAK", String(format: "%5.2f", frame.peak), color: frame.peak > 0.99 ? .red : Theme.textPrimary)
            metric("CORR", String(format: "%+.2f", frame.correlation), color: Theme.textPrimary)
            metric("CENT", String(format: "%3.0f", frame.centroid * 9000), color: Theme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
        }
    }

    private var lufsColor: Color {
        if frame.loudness > -6 { return .red }
        if frame.loudness > -9 { return .yellow }
        return Theme.textPrimary
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.monoSmall)
                .tracking(1.6)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private var bandLegend: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("20 Hz")
            Text("200 Hz")
            Text("2 kHz")
            Text("20 kHz")
        }
        .font(Theme.monoSmall)
        .foregroundStyle(Theme.textTertiary)
        .padding(.bottom, 2)
    }
}

// MARK: - 窗口访问器

struct WindowAccessor: NSViewRepresentable {

    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
