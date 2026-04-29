//
//  LoginItem.swift
//  AgentRunner
//
//  SMAppService 래퍼 (macOS 13+).
//

import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    NSLog("AgentRunner: launch-at-login enabled")
                }
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("AgentRunner: launch-at-login disabled")
            }
        } catch {
            NSLog("AgentRunner: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
