//
//  main.swift
//  Lyrascope
//
//  入口。用 main.swift 而不是 @main，是为了在启动 NSApplication 之前
//  处理 --selftest，让自检可以在后台、无界面、无 WindowServer 交互的情况下跑完。
//

import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
