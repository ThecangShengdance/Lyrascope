//
//  SettingsView.swift
//  Lyrascope
//
//  设置窗口：左侧极简导航，右侧就地修改、即时生效。
//

import AppKit
import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var section: Section = .appearance

    enum Section: String, CaseIterable, Identifiable {
        case appearance
        case lyrics
        case audio
        case menuBar
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "外观"
            case .lyrics: return "歌词"
            case .audio: return "音频"
            case .menuBar: return "菜单栏"
            case .about: return "关于"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "sparkles"
            case .lyrics: return "text.quote"
            case .audio: return "waveform"
            case .menuBar: return "menubar.rectangle"
            case .about: return "info.circle"
            }
        }
    }

    private var accent: Theme.Accent { Theme.accent(settings.lyricsAccent) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(accent.primary)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.canvas)
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Lyrascope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.top, 26)
                .padding(.bottom, 14)

            ForEach(Section.allCases) { item in
                let active = item == section
                Button {
                    withAnimation(.snappy(duration: 0.24)) { section = item }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(active ? Color.white.opacity(0.08) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.horizontal, 8)
            }

            Spacer()

            Text("词镜 · \(version)")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(width: 168)
        .background(Color.white.opacity(0.02))
    }

    // MARK: 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var subtitle: String {
        switch section {
        case .appearance: return "画面怎么流动，由你决定。"
        case .lyrics: return "歌词从哪里来，长什么样。"
        case .audio: return "Lyrascope 只读取系统正在播放的声音，不会打开麦克风。"
        case .menuBar: return "常驻菜单栏时的样子。"
        case .about: return "版本、许可和一点说明。"
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch section {
        case .appearance: appearanceSection
        case .lyrics: lyricsSection
        case .audio: audioSection
        case .menuBar: menuBarSection
        case .about: aboutSection
        }
    }

    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            ForEach(VisualMode.allCases) { mode in
                let active = settings.visualMode == mode
                Button {
                    withAnimation(.snappy(duration: 0.25)) { settings.visualMode = mode }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(active ? Color.black.opacity(0.82) : accent.primary)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(active ? Color.black.opacity(0.10) : Color.white.opacity(0.06))
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.textPrimary)
                            Text(mode.subtitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(active ? Color.black.opacity(0.55) : Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(active
                                  ? AnyShapeStyle(Theme.gradient(settings.lyricsAccent))
                                  : AnyShapeStyle(Color.white.opacity(0.04)))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(active ? Color.clear : Theme.stroke, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.subtitle)
            }
        }
    }

    private var appearanceSection: some View {
        GlassPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 2) {
                SettingRow(title: "可视化视图", subtitle: "五种视图，⌘1–⌘5 可直接切换。") {
                    EmptyView()
                }

                modeGrid
                    .padding(.bottom, 6)

                SettingDivider()

                SettingRow(title: "强调色", subtitle: "同时影响界面点缀与画面配色。") {
                    HStack(spacing: 6) {
                        ForEach(AccentStyle.allCases) { style in
                            Circle()
                                .fill(Theme.gradient(style))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle().strokeBorder(
                                        settings.lyricsAccent == style ? Color.white : Color.white.opacity(0.15),
                                        lineWidth: settings.lyricsAccent == style ? 2 : 1
                                    )
                                }
                                .onTapGesture { settings.lyricsAccent = style }
                                .help(style.title)
                        }
                    }
                }

                SettingDivider()

                sliderRow("光晕强度", value: $settings.bloom, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
                SettingDivider()
                sliderRow("背景压暗", value: $settings.backgroundDim, range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })

                SettingDivider()

                SettingRow(title: "渲染帧率", subtitle: "30 更省电，60 更顺滑。") {
                    SegmentedBar(
                        items: [60, 30],
                        title: { $0 == 60 ? "60 fps" : "30 fps" },
                        selection: Binding(
                            get: { settings.renderFPS },
                            set: { settings.renderFPS = $0 }
                        ),
                        accent: accent.primary
                    )
                }

                SettingRow(title: "窗口置顶", subtitle: "画面浮在其他窗口之上。") {
                    Toggle("", isOn: $settings.alwaysOnTop).labelsHidden().toggleStyle(.switch)
                }

                SettingDivider()

                SettingRow(title: "显示控件", subtitle: "鼠标静止几秒后自动淡出。") {
                    Toggle("", isOn: $settings.showChrome).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var lyricsSection: some View {
        VStack(spacing: 16) {
            GlassPanel(padding: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingRow(title: "桌面歌词", subtitle: "一个可拖动、可穿透的悬浮歌词窗口。") {
                        Toggle("", isOn: $settings.showDesktopLyrics).labelsHidden().toggleStyle(.switch)
                    }

                    SettingDivider()

                    sliderRow("字号", value: $settings.lyricsFontSize, range: 16...64, format: { String(format: "%.0f pt", $0) })

                    SettingDivider()

                    SettingRow(title: "行数") {
                        SegmentedBar(
                            items: LyricsFit.allCases,
                            title: { $0.title },
                            selection: $settings.lyricsFit,
                            accent: accent.primary
                        )
                        .frame(width: 130)
                    }

                    SettingDivider()

                    SettingRow(title: "对齐") {
                        SegmentedBar(
                            items: LyricsAlignment.allCases,
                            title: { $0.title },
                            selection: $settings.lyricsAlignment,
                            accent: accent.primary
                        )
                        .frame(width: 130)
                    }

                    SettingDivider()

                    sliderRow("不透明度", value: $settings.lyricsOpacity, range: 0.2...1, format: { String(format: "%.0f%%", $0 * 100) })

                    SettingDivider()

                    SettingRow(title: "歌词背景", subtitle: "关闭后只剩文字与阴影。") {
                        Toggle("", isOn: $settings.lyricsShowBackground).labelsHidden().toggleStyle(.switch)
                    }

                    SettingDivider()

                    SettingRow(title: "鼠标穿透", subtitle: "开启后点击会落到下面的窗口，需要关闭才能拖动歌词。") {
                        Toggle("", isOn: $settings.lyricsClickThrough).labelsHidden().toggleStyle(.switch)
                    }

                    SettingDivider()

                    SettingRow(title: "显示翻译", subtitle: "如果歌词文件里带翻译行，会显示在下方。") {
                        Toggle("", isOn: $settings.showTranslation).labelsHidden().toggleStyle(.switch)
                    }

                    SettingRow(title: "自动翻译", subtitle: "没有翻译时，用系统翻译在本机补一份（不联网存歌词）。") {
                        Toggle("", isOn: $settings.autoTranslate).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            GlassPanel(padding: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingRow(title: "歌词时间偏移", subtitle: "歌词比声音快就往左调。") {
                        HStack(spacing: 10) {
                            Slider(value: $settings.lyricsOffset, in: -2...2)
                                .frame(width: 170)
                            Text(String(format: "%+.2f s", settings.lyricsOffset))
                                .font(Theme.mono)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }

                    SettingDivider()

                    SettingRow(title: "LRCLIB 在线歌词", subtitle: "按曲名与歌手查询公开的 LRC 时间轴。") {
                        Toggle("", isOn: $settings.enableLRCLib).labelsHidden().toggleStyle(.switch)
                    }

                    SettingDivider()

                    SettingRow(title: "Apple Music 本地歌词", subtitle: "仅对已下载、且内嵌歌词的曲目有效。") {
                        Toggle("", isOn: $settings.enableAppleMusicLyrics).labelsHidden().toggleStyle(.switch)
                    }

                    SettingDivider()

                    SettingRow(title: "本地歌词文件夹", subtitle: folderLabel) {
                        PillButton(title: "选择…", systemName: "folder", accent: accent.primary) {
                            pickFolder()
                        }
                    }

                    if !settings.localLyricsFolder.isEmpty {
                        HStack {
                            Spacer()
                            Button("清除") { settings.localLyricsFolder = "" }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private var folderLabel: String {
        if settings.localLyricsFolder.isEmpty {
            return "选择一个装满 .lrc 的文件夹，命中优先级最高。"
        }
        return (settings.localLyricsFolder as NSString).abbreviatingWithTildeInPath
    }

    private var audioSection: some View {
        GlassPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 2) {
                SettingRow(title: "采集方式", subtitle: settings.captureMode.subtitle) {
                    SegmentedBar(
                        items: CaptureMode.allCases,
                        title: { $0.rawValue == "systemTap" ? "进程 Tap" : "屏幕录制" },
                        selection: $settings.captureMode,
                        accent: accent.primary
                    )
                    .frame(width: 190)
                }

                SettingDivider()

                sliderRow("输入增益", value: $settings.inputGain, range: 0.2...2.0, format: { String(format: "%.2f×", $0) })

                SettingDivider()

                SettingRow(title: "当前状态", subtitle: model.statusText) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.captureState.isRunning ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        PillButton(title: "重新连接", systemName: "arrow.clockwise", accent: accent.primary) {
                            model.retryAudio()
                        }
                    }
                }

                SettingDivider()

                Text("Lyrascope 通过 Core Audio 的进程音频 Tap 读取系统正在播放的声音，不访问麦克风，也不会上传任何音频。如果系统拒绝授权，请在「系统设置 › 隐私与安全性 › 录屏与系统录音」中允许 Lyrascope。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private var menuBarSection: some View {
        GlassPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 2) {
                SettingRow(title: "菜单栏显示歌词", subtitle: "把当前这句歌词放进状态栏。") {
                    Toggle("", isOn: $settings.menuBarLyrics).labelsHidden().toggleStyle(.switch)
                }

                SettingDivider()

                SettingRow(title: "菜单栏频谱图标", subtitle: "四个小柱子跟着音乐跳动。") {
                    Toggle("", isOn: $settings.menuBarShowSpectrum).labelsHidden().toggleStyle(.switch)
                }

                SettingDivider()

                SettingRow(title: "仅菜单栏模式", subtitle: "隐藏主窗口，只留菜单栏与桌面歌词。") {
                    Toggle("", isOn: $settings.menuBarOnly).labelsHidden().toggleStyle(.switch)
                }

                SettingDivider()

                SettingRow(title: "开机时启动", subtitle: "登录后自动在菜单栏待命。") {
                    Toggle("", isOn: Binding(
                        get: { LoginItem.isEnabled },
                        set: { value in
                            settings.launchAtLogin = value
                            Task { await LoginItem.setEnabled(value) }
                        }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(spacing: 16) {
            GlassPanel(padding: 20) {
                HStack(alignment: .top, spacing: 16) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.gradient(settings.lyricsAccent))
                        .frame(width: 58, height: 58)
                        .overlay {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.black.opacity(0.75))
                        }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lyrascope 词镜")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("版本 \(version) · MIT License")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text("一个纯本地的音乐可视化与歌词工具。没有账号、没有遥测、没有云端。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }

            GlassPanel(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("第三方组件")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("本项目没有引入任何第三方依赖，全部代码为原创，只使用 Apple 系统框架（SwiftUI、AppKit、Metal、Accelerate、ScreenCaptureKit、Core Audio）。详细审查见仓库内 Docs/LICENSE-AUDIT.md。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Theme.stroke).padding(.vertical, 4)

                    Text("歌词版权")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("歌词文本来自你自己提供的 LRC 文件、Apple Music 本地曲库或 LRCLIB 公开数据库，Lyrascope 不附带、不再分发任何歌词内容。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 小组件

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        SettingRow(title: title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 190)
                Text(format(value.wrappedValue))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 54, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择一个包含 .lrc 歌词文件的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            settings.localLyricsFolder = url.path
        }
    }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }
}
