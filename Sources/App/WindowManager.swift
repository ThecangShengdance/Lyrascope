//
//  WindowManager.swift
//  Lyrascope
//
//  三张画布：主窗口、桌面歌词浮窗、菜单栏。全部用 AppKit 直接管理，
//  SwiftUI 只负责里面长什么样。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowManager: NSObject {

    static let shared = WindowManager()

    private(set) var mainWindow: NSWindow?
    /// `showMainWindow()` 会把「仅菜单栏」关掉，而关闭动作又会回调到订阅里；
    /// 用一个标志挡住重入，否则会递归到爆栈（曾因此崩溃）。
    private var isSyncingMenuBarOnly = false
    private var lyricsPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private var model: AppModel { AppModel.shared }

    private var hosting: (AnyView) -> AnyView { { $0 } }

    // MARK: - 装配

    func setUp() {
        buildMainWindow()
        buildLyricsPanel()
        buildStatusItem()
        observeSettings()
        startStatusTicker()
        updateLyricsVisibility()
    }

    private func rootView() -> some View {
        RootView()
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.translator)
            .preferredColorScheme(.dark)
    }

    private func buildMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lyrascope"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.minSize = NSSize(width: 880, height: 520)
        window.isReleasedWhenClosed = false
        window.level = model.settings.alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: rootView())
        window.setFrameAutosaveName("Lyrascope.MainWindow")
        window.center()
        mainWindow = window

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )

        if !model.settings.menuBarOnly {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func buildLyricsPanel() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 960, height: 190)
        let panel = NSPanel(
            contentRect: defaultFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 面板里的 Material 会按窗口外观取色：强制深色，浅色壁纸上才不会糊成白板
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = model.settings.lyricsClickThrough
        panel.contentView = NSHostingView(
            rootView: LyricsOverlayView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.translator)
                .preferredColorScheme(.dark)
        )

        let saved = model.settings.lyricsPanelFrame
        if saved.width > 120, saved.height > 60 {
            panel.setFrame(saved, display: false)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: frame.midX - defaultFrame.width / 2,
                    y: frame.minY + 120,
                    width: defaultFrame.width,
                    height: defaultFrame.height
                ),
                display: false
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lyricsPanelDidMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        lyricsPanel = panel
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarGlyph.image(frame: model.frame, accent: model.settings.lyricsAccent)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 468)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.translator)
                .preferredColorScheme(.dark)
        )
        self.popover = popover
        statusItem = item
        refreshStatusItem()
    }

    // MARK: - 设置联动

    private func observeSettings() {
        let settings = model.settings

        settings.$showDesktopLyrics
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLyricsVisibility() } }
            .store(in: &cancellables)

        settings.$alwaysOnTop
            .dropFirst()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.mainWindow?.level = value ? .floating : .normal }
            }
            .store(in: &cancellables)

        model.$track
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLyricsVisibility() } }
            .store(in: &cancellables)

        model.lyrics.$currentText
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLyricsVisibility() } }
            .store(in: &cancellables)

        settings.$lyricsClickThrough
            .dropFirst()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.lyricsPanel?.ignoresMouseEvents = value }
            }
            .store(in: &cancellables)

        settings.$menuBarOnly
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] only in
                MainActor.assumeIsolated {
                    guard let self, !self.isSyncingMenuBarOnly else { return }
                    if only {
                        self.mainWindow?.orderOut(nil)
                    } else {
                        self.showMainWindow()
                    }
                }
            }
            .store(in: &cancellables)

        settings.$menuBarLyrics
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatusItem() } }
            .store(in: &cancellables)
    }

    // MARK: - 菜单栏刷新

    private func startStatusTicker() {
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusItem() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func refreshStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let settings = model.settings
        let accent = settings.lyricsAccent

        let lyric = model.lyrics.currentText
        let showText = settings.menuBarLyrics && !lyric.isEmpty
        let showGlyph = settings.menuBarShowSpectrum

        let lyricProgress = CGFloat(min(max(model.lyrics.progress, 0), 1))
        button.image = showGlyph ? MenuBarGlyph.image(frame: model.frame, accent: accent) : nil
        button.imagePosition = showGlyph ? (showText ? .imageLeading : .imageOnly) : .noImage

        if showText {
            let trimmed = lyric.count > 42 ? String(lyric.prefix(41)) + "…" : lyric
            button.attributedTitle = Self.karaokeTitle(
                text: trimmed,
                progress: lyricProgress,
                accent: Theme.accent(settings.lyricsAccent).primary
            )
            item.length = NSStatusItem.variableLength
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            item.length = showGlyph ? NSStatusItem.variableLength : 26
        }
    }

    /// 菜单栏里的逐字高亮：唱过的部分用强调色，没唱的还是系统文字色。
    /// 单个字符一步，42 个字符的宽度下已经很连贯，并且跟桌面歌词完全同步。
    private static func karaokeTitle(text: String, progress: CGFloat, accent: Color) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let attributed = NSMutableAttributedString(string: " " + text, attributes: base)
        let count = text.count
        guard count > 0 else { return attributed }

        let sung = Int((Double(count) * Double(min(max(progress, 0), 1))).rounded())
        if sung > 0 {
            let range = NSRange(location: 1, length: sung)
            attributed.addAttribute(.foregroundColor,
                                    value: NSColor(accent),
                                    range: range)
        }
        return attributed
    }

    // MARK: - 动作

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        togglePopover()
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开 Lyrascope", action: #selector(showMainWindowAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let lyrics = NSMenuItem(title: "桌面歌词", action: #selector(toggleLyricsAction), keyEquivalent: "")
        lyrics.target = self
        lyrics.state = model.settings.showDesktopLyrics ? .on : .off
        menu.addItem(lyrics)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出 Lyrascope", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showMainWindow() {
        guard let window = mainWindow else { return }
        if model.settings.menuBarOnly {
            isSyncingMenuBarOnly = true
            model.settings.menuBarOnly = false
            isSyncingMenuBarOnly = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Lyrascope 设置"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(model)
                    .environmentObject(model.settings)
                    .environmentObject(model.translator)
                    .preferredColorScheme(.dark)
            )
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleLyricsPanel() {
        model.toggleLyrics()
    }

    func updateLyricsVisibility() {
        guard let panel = lyricsPanel else { return }
        // 没有曲目、也没有歌词时不必在桌面下方挂一块空面板。
        let hasContent = model.track != nil || !model.lyrics.currentText.isEmpty
        if model.settings.showDesktopLyrics && hasContent {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func showMainWindowAction() { showMainWindow() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func toggleLyricsAction() {
        model.settings.showDesktopLyrics.toggle()
        updateLyricsVisibility()
    }

    // MARK: - 通知

    @objc private func mainWindowDidEnterFullScreen() { model.setFullScreen(true) }
    @objc private func mainWindowDidExitFullScreen() { model.setFullScreen(false) }

    @objc private func lyricsPanelDidMove() {
        guard let panel = lyricsPanel else { return }
        model.settings.lyricsPanelFrame = panel.frame
    }
}

// MARK: - 菜单栏小图标

enum MenuBarGlyph {

    static func image(frame: AudioFrame, accent: AccentStyle) -> NSImage? {
        let height: CGFloat = 18
        let width: CGFloat = 24
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bars = 5
            let gap: CGFloat = 2.6
            let barWidth = (rect.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            let level = CGFloat(max(frame.level, 0.06))
            // 静音时也留一个「波形静止」造型，避免变成几根等高短横线。
            let idlePattern: [CGFloat] = [0.26, 0.52, 0.86, 0.62, 0.34]
            let baseline: CGFloat = 2.0
            let available = rect.height - baseline * 2

            for index in 0..<bars {
                let bandIndex = min(AudioFrame.bandCount - 1, 2 + index * 13)
                let live = min(1.0, CGFloat(frame.bands[bandIndex]))
                // 0…1 拉到 0.22…1：矮的柱也能看出差异，不会挤成一条直线
                let shaped = 0.22 + 0.78 * pow(live, 0.85)
                let normalized: CGFloat = frame.isSilent
                    ? idlePattern[index] * (0.70 + 0.28 * level)
                    : max(idlePattern[index] * 0.40, shaped)
                let barHeight = max(3.5, available * normalized)
                let x = CGFloat(index) * (barWidth + gap)
                let path = NSBezierPath(
                    roundedRect: NSRect(x: x, y: baseline, width: barWidth, height: barHeight),
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                )
                NSColor.white.withAlphaComponent(0.95).setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
