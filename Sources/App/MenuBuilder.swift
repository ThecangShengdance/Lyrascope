//
//  MenuBuilder.swift
//  Lyrascope
//
//  手写主菜单：Xcode 的 SwiftUI App 模板不方便做菜单栏 App，这里干脆直接建 NSMenu。
//

import AppKit

enum MenuBuilder {

    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target))
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: App

    private static func appMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        let about = NSMenuItem(title: "关于 Lyrascope", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        about.target = target
        menu.addItem(about)

        let settings = NSMenuItem(title: "设置…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        menu.addItem(settings)

        menu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏 Lyrascope", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Lyrascope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.submenu = menu
        return item
    }

    // MARK: 视图

    private static func viewMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "视图")

        for (index, mode) in VisualMode.allCases.enumerated() {
            let item = NSMenuItem(
                title: "\(mode.title)视图",
                action: #selector(AppDelegate.selectVisualMode(_:)),
                keyEquivalent: String(index + 1)
            )
            item.tag = mode.shaderIndex
            item.target = target
            menu.addItem(item)
        }

        let next = NSMenuItem(title: "切换到下一个视图", action: #selector(AppDelegate.cycleVisualMode(_:)), keyEquivalent: "")
        next.target = target
        menu.addItem(next)

        menu.addItem(.separator())

        let lyrics = NSMenuItem(title: "桌面歌词", action: #selector(AppDelegate.toggleLyrics(_:)), keyEquivalent: "l")
        lyrics.target = target
        lyrics.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(lyrics)

        let onTop = NSMenuItem(title: "窗口置顶", action: #selector(AppDelegate.toggleAlwaysOnTop(_:)), keyEquivalent: "t")
        onTop.target = target
        onTop.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(onTop)

        let menuBarOnly = NSMenuItem(title: "仅菜单栏模式", action: #selector(AppDelegate.toggleMenuBarOnly(_:)), keyEquivalent: "")
        menuBarOnly.target = target
        menu.addItem(menuBarOnly)

        menu.addItem(.separator())

        let fullScreen = NSMenuItem(
            title: "进入全屏",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(fullScreen)

        item.submenu = menu
        return item
    }

    // MARK: 编辑（文本框需要）

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        menu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "剪切", action: Selector(("cut:")), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "拷贝", action: Selector(("copy:")), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "粘贴", action: Selector(("paste:")), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "全选", action: Selector(("selectAll:")), keyEquivalent: "a"))
        item.submenu = menu
        return item
    }

    // MARK: 窗口

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        menu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
