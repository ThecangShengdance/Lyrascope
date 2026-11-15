//
//  Settings.swift
//  Lyrascope
//
//  Created by zhangzhouqi on 2026/11/15.
//  Copyright © 2026 zhangzhouqi. MIT License.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - 可视化模式

enum VisualMode: String, Codable, CaseIterable, Identifiable {
    /// 面向普通听众：流动的极光、粒子与频谱光环。
    case aurora
    /// 面向音乐制作者：频谱瀑布、示波器、声像仪、响度表。
    case studio
    /// 无限延伸的棱镜隧道，频谱化作环与辐条。
    case prism
    /// 水面涟漪，频谱是一圈荡开的光带。
    case ripple
    /// 声波化作层叠山脊，落日藏在后面。
    case ridge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "流光"
        case .studio: return "制作人"
        case .prism: return "棱镜"
        case .ripple: return "涟漪"
        case .ridge: return "峰峦"
        }
    }

    var subtitle: String {
        switch self {
        case .aurora: return "极光 · 粒子 · 频谱光环"
        case .studio: return "瀑布图 · 示波器 · 声像仪"
        case .prism: return "无限隧道 · 环与辐条"
        case .ripple: return "水面 · 涟漪 · 光带"
        case .ridge: return "山脊 · 落日 · 声波轮廓"
        }
    }

    /// 与着色器里的 mode uniform 对应。
    var shaderIndex: Int {
        switch self {
        case .aurora: return 0
        case .studio: return 1
        case .prism: return 2
        case .ripple: return 3
        case .ridge: return 4
        }
    }

    /// 是否属于「制作人」类（会叠加仪表 HUD）。
    var isAnalytic: Bool { self == .studio }

    var symbol: String {
        switch self {
        case .aurora: return "sparkles"
        case .studio: return "waveform.path.ecg.rectangle"
        case .prism: return "triangle"
        case .ripple: return "water.waves"
        case .ridge: return "mountain.2"
        }
    }
}

// MARK: - 强调色

enum AccentStyle: String, Codable, CaseIterable, Identifiable {
    case aurora
    case gold
    case ice
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "极光"
        case .gold: return "暖金"
        case .ice: return "冰蓝"
        case .mono: return "月白"
        }
    }

    var primary: Color {
        switch self {
        case .aurora: return Color(red: 0.42, green: 0.85, blue: 0.95)
        case .gold: return Color(red: 1.00, green: 0.78, blue: 0.45)
        case .ice: return Color(red: 0.55, green: 0.78, blue: 1.00)
        case .mono: return Color(white: 0.96)
        }
    }

    var secondary: Color {
        switch self {
        case .aurora: return Color(red: 0.62, green: 0.47, blue: 1.00)
        case .gold: return Color(red: 1.00, green: 0.55, blue: 0.38)
        case .ice: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .mono: return Color(white: 0.72)
        }
    }
}

// MARK: - 采集方式

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    /// Core Audio 进程 Tap（macOS 14.2+）。只录系统声音，不碰麦克风。
    case systemTap
    /// ScreenCaptureKit 音频（备选方案）。需要「屏幕录制」权限。
    case screenCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemTap: return "进程音频 Tap"
        case .screenCapture: return "屏幕录制音频"
        }
    }

    var subtitle: String {
        switch self {
        case .systemTap: return "推荐 · 需要「音频录制」权限"
        case .screenCapture: return "备选 · 部分系统版本收不到数据，建议用进程 Tap"
        }
    }
}

// MARK: - 歌词对齐方式

enum LyricsAlignment: String, Codable, CaseIterable, Identifiable {
    case center
    case leading

    var id: String { rawValue }
    var title: String { self == .center ? "居中" : "左对齐" }
}

enum LyricsFit: String, Codable, CaseIterable, Identifiable {
    case twoLines
    case threeLines

    var id: String { rawValue }
    var title: String { self == .twoLines ? "两行" : "三行" }
    var lineCount: Int { self == .twoLines ? 2 : 3 }
}

// MARK: - 设置存储

/// 全部设置都在这里。任何一次修改都会立即写入 UserDefaults，
/// 所以强制退出也不会丢配置。
@MainActor
final class SettingsStore: ObservableObject {

    private static let storageKey = "Lyrascope.settings.v1"

    // 可视化
    @Published var visualMode: VisualMode = .aurora { didSet { persist() } }
    @Published var bloom: Double = 0.72 { didSet { persist() } }
    @Published var backgroundDim: Double = 0.55 { didSet { persist() } }
    @Published var reduceMotion: Bool = false { didSet { persist() } }
    /// 可视化渲染帧率。30 更省电，60 更顺滑。
    @Published var renderFPS: Int = 60 { didSet { persist() } }
    @Published var showChrome: Bool = true { didSet { persist() } }
    @Published var alwaysOnTop: Bool = true { didSet { persist() } }

    // 桌面歌词
    @Published var showDesktopLyrics: Bool = true { didSet { persist() } }
    @Published var lyricsFontSize: Double = 30 { didSet { persist() } }
    @Published var lyricsFit: LyricsFit = .twoLines { didSet { persist() } }
    @Published var lyricsAlignment: LyricsAlignment = .center { didSet { persist() } }
    @Published var lyricsAccent: AccentStyle = .aurora { didSet { persist() } }
    @Published var lyricsShowBackground: Bool = true { didSet { persist() } }
    @Published var lyricsOpacity: Double = 1.0 { didSet { persist() } }
    @Published var lyricsClickThrough: Bool = false { didSet { persist() } }
    @Published var lyricsPanelFrame: NSRect = .zero { didSet { persist() } }

    // 菜单栏
    @Published var menuBarLyrics: Bool = true { didSet { persist() } }
    @Published var menuBarShowSpectrum: Bool = true { didSet { persist() } }
    @Published var menuBarOnly: Bool = false { didSet { persist() } }

    // 采集
    @Published var captureMode: CaptureMode = .systemTap { didSet { persist() } }
    @Published var inputGain: Double = 1.0 { didSet { persist() } }

    // 歌词来源
    @Published var enableLRCLib: Bool = true { didSet { persist() } }
    @Published var enableAppleMusicLyrics: Bool = true { didSet { persist() } }
    @Published var lyricsOffset: Double = 0 { didSet { persist() } }
    @Published var localLyricsFolder: String = "" { didSet { persist() } }
    @Published var showTranslation: Bool = true { didSet { persist() } }
    /// 没有翻译时用系统「翻译」框架在本地翻一遍（只对同步歌词生效）。
    @Published var autoTranslate: Bool = true { didSet { persist() } }

    // 系统
    @Published var launchAtLogin: Bool = false { didSet { persist() } }
    @Published var hasCompletedOnboarding: Bool = false { didSet { persist() } }

    private var isLoading = true

    init() {
        load()
        isLoading = false
    }

    // MARK: 持久化

    private struct Snapshot: Codable {
        var visualMode: VisualMode
        var bloom: Double
        var backgroundDim: Double
        var reduceMotion: Bool
        var renderFPS: Int
        var showChrome: Bool
        var alwaysOnTop: Bool
        var showDesktopLyrics: Bool
        var lyricsFontSize: Double
        var lyricsFit: LyricsFit
        var lyricsAlignment: LyricsAlignment
        var lyricsAccent: AccentStyle
        var lyricsShowBackground: Bool
        var lyricsOpacity: Double
        var lyricsClickThrough: Bool
        var lyricsPanelFrame: String
        var menuBarLyrics: Bool
        var menuBarShowSpectrum: Bool
        var menuBarOnly: Bool
        var captureMode: CaptureMode
        var inputGain: Double
        var enableLRCLib: Bool
        var enableAppleMusicLyrics: Bool
        var lyricsOffset: Double
        var localLyricsFolder: String
        var showTranslation: Bool
        var autoTranslate: Bool
        var launchAtLogin: Bool
        var hasCompletedOnboarding: Bool


        init(
            visualMode: VisualMode,
            bloom: Double,
            backgroundDim: Double,
            reduceMotion: Bool,
            renderFPS: Int,
            showChrome: Bool,
            alwaysOnTop: Bool,
            showDesktopLyrics: Bool,
            lyricsFontSize: Double,
            lyricsFit: LyricsFit,
            lyricsAlignment: LyricsAlignment,
            lyricsAccent: AccentStyle,
            lyricsShowBackground: Bool,
            lyricsOpacity: Double,
            lyricsClickThrough: Bool,
            lyricsPanelFrame: String,
            menuBarLyrics: Bool,
            menuBarShowSpectrum: Bool,
            menuBarOnly: Bool,
            captureMode: CaptureMode,
            inputGain: Double,
            enableLRCLib: Bool,
            enableAppleMusicLyrics: Bool,
            lyricsOffset: Double,
            localLyricsFolder: String,
            showTranslation: Bool,
            autoTranslate: Bool,
            launchAtLogin: Bool,
            hasCompletedOnboarding: Bool
        ) {
            self.visualMode = visualMode
            self.bloom = bloom
            self.backgroundDim = backgroundDim
            self.reduceMotion = reduceMotion
            self.renderFPS = renderFPS
            self.showChrome = showChrome
            self.alwaysOnTop = alwaysOnTop
            self.showDesktopLyrics = showDesktopLyrics
            self.lyricsFontSize = lyricsFontSize
            self.lyricsFit = lyricsFit
            self.lyricsAlignment = lyricsAlignment
            self.lyricsAccent = lyricsAccent
            self.lyricsShowBackground = lyricsShowBackground
            self.lyricsOpacity = lyricsOpacity
            self.lyricsClickThrough = lyricsClickThrough
            self.lyricsPanelFrame = lyricsPanelFrame
            self.menuBarLyrics = menuBarLyrics
            self.menuBarShowSpectrum = menuBarShowSpectrum
            self.menuBarOnly = menuBarOnly
            self.captureMode = captureMode
            self.inputGain = inputGain
            self.enableLRCLib = enableLRCLib
            self.enableAppleMusicLyrics = enableAppleMusicLyrics
            self.lyricsOffset = lyricsOffset
            self.localLyricsFolder = localLyricsFolder
            self.showTranslation = showTranslation
            self.autoTranslate = autoTranslate
            self.launchAtLogin = launchAtLogin
            self.hasCompletedOnboarding = hasCompletedOnboarding
        }

        init(from decoder: Decoder) throws {

            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
            }
            self.init(
                visualMode: value(.visualMode, .aurora),
                bloom: value(.bloom, 0.72),
                backgroundDim: value(.backgroundDim, 0.55),
                reduceMotion: value(.reduceMotion, false),
                renderFPS: value(.renderFPS, 60),
                showChrome: value(.showChrome, true),
                alwaysOnTop: value(.alwaysOnTop, true),
                showDesktopLyrics: value(.showDesktopLyrics, true),
                lyricsFontSize: value(.lyricsFontSize, 30),
                lyricsFit: value(.lyricsFit, .twoLines),
                lyricsAlignment: value(.lyricsAlignment, .center),
                lyricsAccent: value(.lyricsAccent, .aurora),
                lyricsShowBackground: value(.lyricsShowBackground, true),
                lyricsOpacity: value(.lyricsOpacity, 1.0),
                lyricsClickThrough: value(.lyricsClickThrough, false),
                lyricsPanelFrame: value(.lyricsPanelFrame, ""),
                menuBarLyrics: value(.menuBarLyrics, true),
                menuBarShowSpectrum: value(.menuBarShowSpectrum, true),
                menuBarOnly: value(.menuBarOnly, false),
                captureMode: value(.captureMode, .systemTap),
                inputGain: value(.inputGain, 1.0),
                enableLRCLib: value(.enableLRCLib, true),
                enableAppleMusicLyrics: value(.enableAppleMusicLyrics, true),
                lyricsOffset: value(.lyricsOffset, 0),
                localLyricsFolder: value(.localLyricsFolder, ""),
                showTranslation: value(.showTranslation, true),
                autoTranslate: value(.autoTranslate, true),
                launchAtLogin: value(.launchAtLogin, false),
                hasCompletedOnboarding: value(.hasCompletedOnboarding, false)
            )
        }
    }

    private func persist() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            visualMode: visualMode,
            bloom: bloom,
            backgroundDim: backgroundDim,
            reduceMotion: reduceMotion,
            renderFPS: renderFPS,
            showChrome: showChrome,
            alwaysOnTop: alwaysOnTop,
            showDesktopLyrics: showDesktopLyrics,
            lyricsFontSize: lyricsFontSize,
            lyricsFit: lyricsFit,
            lyricsAlignment: lyricsAlignment,
            lyricsAccent: lyricsAccent,
            lyricsShowBackground: lyricsShowBackground,
            lyricsOpacity: lyricsOpacity,
            lyricsClickThrough: lyricsClickThrough,
            lyricsPanelFrame: NSStringFromRect(lyricsPanelFrame),
            menuBarLyrics: menuBarLyrics,
            menuBarShowSpectrum: menuBarShowSpectrum,
            menuBarOnly: menuBarOnly,
            captureMode: captureMode,
            inputGain: inputGain,
            enableLRCLib: enableLRCLib,
            enableAppleMusicLyrics: enableAppleMusicLyrics,
            lyricsOffset: lyricsOffset,
            localLyricsFolder: localLyricsFolder,
            showTranslation: showTranslation,
            autoTranslate: autoTranslate,
            launchAtLogin: launchAtLogin,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }

        visualMode = snapshot.visualMode
        bloom = snapshot.bloom
        backgroundDim = snapshot.backgroundDim
        reduceMotion = snapshot.reduceMotion
        renderFPS = snapshot.renderFPS
        showChrome = snapshot.showChrome
        alwaysOnTop = snapshot.alwaysOnTop
        showDesktopLyrics = snapshot.showDesktopLyrics
        lyricsFontSize = snapshot.lyricsFontSize
        lyricsFit = snapshot.lyricsFit
        lyricsAlignment = snapshot.lyricsAlignment
        lyricsAccent = snapshot.lyricsAccent
        lyricsShowBackground = snapshot.lyricsShowBackground
        lyricsOpacity = snapshot.lyricsOpacity
        lyricsClickThrough = snapshot.lyricsClickThrough
        lyricsPanelFrame = NSRectFromString(snapshot.lyricsPanelFrame)
        menuBarLyrics = snapshot.menuBarLyrics
        menuBarShowSpectrum = snapshot.menuBarShowSpectrum
        menuBarOnly = snapshot.menuBarOnly
        captureMode = snapshot.captureMode
        inputGain = snapshot.inputGain
        enableLRCLib = snapshot.enableLRCLib
        enableAppleMusicLyrics = snapshot.enableAppleMusicLyrics
        lyricsOffset = snapshot.lyricsOffset
        localLyricsFolder = snapshot.localLyricsFolder
        showTranslation = snapshot.showTranslation
        autoTranslate = snapshot.autoTranslate
        launchAtLogin = snapshot.launchAtLogin
        hasCompletedOnboarding = snapshot.hasCompletedOnboarding
    }
}
