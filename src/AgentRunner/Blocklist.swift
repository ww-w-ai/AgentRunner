//
//  Blocklist.swift
//  AgentRunner
//
//  AI 클라이언트가 아님이 명확한 프로세스 차단 목록.
//  큐레이션은 우리가 관리, 사용자 편집 X (PLAN.md 정책).
//  nettop은 프로세스명을 잘라서 주는 경우가 많아 substring 매칭 사용.
//

import Foundation

enum Blocklist {

    /// 차단할 프로세스명 패턴 (대소문자 무시, contains 매칭)
    static let patterns: [String] = [
        // 브라우저
        "Google Chrome",
        "Chrome Helper",
        "Chromium",
        "Safari",
        "WebKit",
        "Firefox",
        "firefox-bin",
        "Microsoft Edge",
        "Edge Helper",
        "Brave",
        "Arc",
        "Opera",
        "Vivaldi",
        "Tor Browser",

        // Electron 텔레메트리
        "Slack Helper",
        "Slack",
        "Notion Helper",
        "Notion",
        "Discord Helper",
        "Discord",

        // 백그라운드 동기화
        "Spotify",
        "Steam",
        "Dropbox",
        "Google Drive",
        "OneDrive",
        "bird",       // iCloud Drive
        "cloudd",     // iCloud
    ]

    static func isBlocked(_ processName: String) -> Bool {
        let lower = processName.lowercased()
        return patterns.contains { lower.contains($0.lowercased()) }
    }
}
