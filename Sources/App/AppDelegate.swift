//
//  AppDelegate.swift
//  Lyrascope
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var model: AppModel { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBuilder.install(target: self)

        WindowManager.shared.setUp()
        model.start()
        model.probeCapturePermission()
        HotKeyCenter.shared.install()

        NSApp.activate(ignoringOtherApps: true)

        // 调试用：`Lyrascope --settings` 直接打开设置窗口，方便截图与排查。
        if CommandLine.arguments.contains("--settings") {
            WindowManager.shared.showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: 菜单动作

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Lyrascope",
            .credits: NSAttributedString(
                string: "词镜 · 本地音乐可视化与歌词\nMIT License © 2026 zhangzhouqi",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings(_ sender: Any?) {
        WindowManager.shared.showSettings()
    }

    @objc func selectVisualMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let mode = VisualMode.allCases.first(where: { $0.shaderIndex == item.tag }) else { return }
        model.selectVisualMode(mode)
    }

    @objc func cycleVisualMode(_ sender: Any?) {
        model.toggleVisualMode()
    }

    @objc func toggleLyrics(_ sender: Any?) {
        model.settings.showDesktopLyrics.toggle()
        WindowManager.shared.updateLyricsVisibility()
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        model.settings.alwaysOnTop.toggle()
    }

    @objc func toggleMenuBarOnly(_ sender: Any?) {
        model.settings.menuBarOnly.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleAlwaysOnTop(_:)):
            menuItem.state = model.settings.alwaysOnTop ? .on : .off
        case #selector(toggleLyrics(_:)):
            menuItem.state = model.settings.showDesktopLyrics ? .on : .off
        case #selector(toggleMenuBarOnly(_:)):
            menuItem.state = model.settings.menuBarOnly ? .on : .off
        case #selector(selectVisualMode(_:)):
            menuItem.state = menuItem.tag == model.settings.visualMode.shaderIndex ? .on : .off
        default:
            break
        }
        return true
    }
}
