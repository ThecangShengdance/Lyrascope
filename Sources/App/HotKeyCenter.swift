//
//  HotKeyCenter.swift
//  Lyrascope
//
//  全局快捷键（Carbon RegisterEventHotKey，不需要辅助功能权限）。
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]

    private let signature: OSType = 0x4C595241 // 'LYRA'

    func install() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                center.actions[hotKeyID.id]?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey), id: 1) {
            AppModel.shared.settings.showDesktopLyrics.toggle()
            WindowManager.shared.updateLyricsVisibility()
        }

        register(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | cmdKey), id: 2) {
            AppModel.shared.toggleFullScreen()
        }

        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey), id: 3) {
            AppModel.shared.toggleVisualMode()
        }

        register(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | cmdKey), id: 4) {
            WindowManager.shared.showMainWindow()
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            NSLog("Lyrascope: 注册快捷键失败 (\(id)) status=\(status)")
            return
        }
        hotKeyRefs.append(hotKeyRef)
        actions[id] = action
    }
}
