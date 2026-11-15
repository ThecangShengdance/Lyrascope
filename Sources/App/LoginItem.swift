//
//  LoginItem.swift
//  Lyrascope
//

import Foundation
import ServiceManagement

enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Lyrascope: 更新登录项失败 \(error.localizedDescription)")
        }
    }
}
