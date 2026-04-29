//
//  SessionPopover.swift
//  AgentRunner
//
//  메뉴바 아이콘 클릭 시 뜨는 팝오버. 활성 세션을 줄 단위로 보여줌.
//

import Cocoa

final class SessionPopover: NSObject, NSPopoverDelegate {

    private let popover = NSPopover()
    private let textView: NSTextView
    private weak var sessions: SessionManager?
    private var refreshTimer: Timer?

    init(sessions: SessionManager) {
        self.sessions = sessions

        let totalW: CGFloat = 380
        let totalH: CGFloat = 260
        let footerH: CGFloat = 24
        let scrollH = totalH - footerH

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // 본문 스크롤
        let scroll = NSScrollView(frame: NSRect(x: 0, y: footerH, width: totalW, height: scrollH))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        scroll.documentView = tv
        self.textView = tv
        super.init()
        popover.delegate = self
        container.addSubview(scroll)

        // 푸터 구분선
        let divider = NSBox(frame: NSRect(x: 0, y: footerH - 0.5, width: totalW, height: 0.5))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .minYMargin]
        container.addSubview(divider)

        // 푸터 힌트 — 오른쪽 클릭으로 메뉴
        let hint = NSTextField(labelWithString: "right-click icon for options")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 0, y: 5, width: totalW, height: 14)
        hint.alignment = .center
        hint.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(hint)

        let vc = NSViewController()
        vc.view = container

        popover.contentViewController = vc
        popover.contentSize = NSSize(width: totalW, height: totalH)
        popover.behavior = .transient
        popover.animates = true
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(below: button)
        }
    }

    private func show(below button: NSStatusBarButton) {
        // 방어: 이전 timer가 살아있으면 정리 (transient close 등)
        refreshTimer?.invalidate()
        refreshTimer = nil

        refreshContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // 열려있는 동안 2s마다 갱신 (SessionManager 3s tick과 비슷한 granularity)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshContent()
        }
    }

    private func close() {
        popover.performClose(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// NSPopoverDelegate — transient 모드에서 사용자가 다른 곳 클릭으로
    /// 자동 dismiss될 때 호출. timer 누수 핵심 fix.
    func popoverDidClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshContent() {
        guard let sessions = sessions else { return }
        let snap = sessions.sessionSnapshot()
            .sorted { $0.bytesInRate > $1.bytesInRate }   // 활발한 순

        // 11pt 모노스페이스 + 380pt 너비 → ~48자가 안전
        let separatorWidth = 48
        let header = "AgentRunner  ·  \(snap.count) session\(snap.count == 1 ? "" : "s")\n"
                   + String(repeating: "─", count: separatorWidth) + "\n"

        let body: String
        if snap.isEmpty {
            body = "\nNo AI traffic detected.\n\nTry sending a request from Claude Code,\nCursor, or any AI client."
        } else {
            body = snap.map { row(for: $0) }.joined(separator: "\n\n")
        }

        textView.string = header + body
    }

    private func row(for s: SessionSnapshot) -> String {
        let dot: String
        switch s.state {
        case .idle:     dot = "○"
        case .scout:    dot = "◔"
        case .running:  dot = "●"
        case .tooling:  dot = "◐"
        }

        let stateName: String
        switch s.state {
        case .idle:     stateName = "idle"
        case .scout:    stateName = "scout"
        case .running:  stateName = "running"
        case .tooling:  stateName = "tooling"
        }

        let inRate  = formatRate(s.bytesInRate)
        let outRate = formatRate(s.bytesOutRate)
        let inGauge  = renderGauge(s.bytesInRate)
        let outGauge = renderGauge(s.bytesOutRate)

        let line1 = "\(dot) \(s.processName)(\(s.pid)) → \(s.provider)  [\(stateName)]"
        let line2 = "  ↓ \(inGauge)  \(inRate)"
        let line3 = "  ↑ \(outGauge)  \(outRate)"
        let line4 = "  total in: \(formatBytes(s.bytesIn))   out: \(formatBytes(s.bytesOut))"
        return line1 + "\n" + line2 + "\n" + line3 + "\n" + line4
    }

    private func renderGauge(_ rate: Double) -> String {
        // 0 ~ 100 KB/s 를 8칸 게이지. 정수 ASCII 블록으로 폭 일관 유지.
        let maxRate: Double = 100_000
        let cells = 8
        let filled = min(cells, Int((rate / maxRate) * Double(cells) + 0.5))
        let on = String(repeating: "█", count: filled)
        let off = String(repeating: "·", count: cells - filled)
        return "[\(on)\(off)]"
    }

    private func formatRate(_ b: Double) -> String {
        if b < 1024 { return String(format: "%5.0f B/s", b) }
        if b < 1024 * 1024 { return String(format: "%5.1f KB/s", b / 1024) }
        return String(format: "%5.1f MB/s", b / 1024 / 1024)
    }

    private func formatBytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d < 1024 { return "\(b)B" }
        if d < 1024 * 1024 { return String(format: "%.1fKB", d / 1024) }
        if d < 1024 * 1024 * 1024 { return String(format: "%.1fMB", d / 1024 / 1024) }
        return String(format: "%.1fGB", d / 1024 / 1024 / 1024)
    }
}
