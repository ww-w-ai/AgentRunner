//
//  AppDelegate.swift
//  AgentRunner
//
//  RunCat 패턴 — NSWindow 없음. 모든 설정/액션은 우클릭 메뉴.
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var animator: CharacterAnimator!
    private var popover: SessionPopover!
    private let menu = NSMenu()
    private let nettop = NettopMonitor()
    private let registry = ProviderRegistry()
    private lazy var sessions = SessionManager(registry: registry)

    // 동적 업데이트 메뉴 항목 (텍스트가 상태에 따라 바뀜)
    private var updateStatusItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private enum UpdateState {
        case idle
        case checking
        case latest
        case available(version: String, url: URL)
        case error(String)
    }
    private var updateState: UpdateState = .idle
    private var lastUpdateCheck: Date = .distantPast
    private let updateCheckTTL: TimeInterval = 3600   // 1h cache

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance lock — 같은 bundle ID의 다른 인스턴스 있으면 자기 종료
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if !others.isEmpty {
            NSLog("AgentRunner: another instance already running (pid=\(others.first?.processIdentifier ?? 0)), exiting")
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        registerSleepWakeObservers()

        registry.start()
        sessions.onAggregateChange = { [weak self] agg in
            self?.animator.render(agg)
        }
        sessions.start()

        nettop.onEvent = { [weak self] event in
            self?.sessions.handle(event: event)
        }
        nettop.start()

        NSLog("AgentRunner: launched")

        // 앱 시작 시 1회 백그라운드 체크
        Task { await self.runUpdateCheck() }

        // 첫 실행 시 Launch at Login 활성화 의향 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.promptLaunchAtLoginIfFirstTime()
        }
    }

    /// 첫 실행에서만 Launch at Login 활성화 여부를 묻는 다이얼로그.
    /// 사용자가 한 번 답하면 다시 묻지 않음 — UserDefaults 키로 추적.
    private func promptLaunchAtLoginIfFirstTime() {
        let key = "hasPromptedLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        // 이미 사용자가 켜놨으면 묻지 않음 (예: brew 재설치)
        if LoginItem.isEnabled { return }

        let alert = NSAlert()
        alert.messageText = "Launch AgentRunner at login?"
        alert.informativeText = """
        AgentRunner lives in your menu bar — it's most useful when always running.
        You can change this anytime from the right-click menu.
        """
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not now")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.setEnabled(true)
            launchAtLoginItem?.state = LoginItem.isEnabled ? .on : .off
            NSLog("AgentRunner: Launch at Login enabled via first-run prompt")
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        nettop.stop()
        sessions.stop()
        registry.stop()
        animator?.stop()
    }

    private func setupStatusItem() {
        // 고정 length — sprite 렌더 폭에 따라 메뉴/팝오버 앵커가 흔들리지 않도록.
        // 80×60 캔버스 → 메뉴바 22pt 높이에 스케일 ≈ 29pt. 세션 카운트(·N) 포함 36pt.
        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        animator = CharacterAnimator(statusItem: statusItem)
        popover = SessionPopover(sessions: sessions)

        animator.renderInitial()

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeft
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMenu()

        NSLog("AgentRunner: status item created")
    }

    private func buildMenu() {
        menu.removeAllItems()
        menu.delegate = self

        // 헤더 — 앱 이름 + 버전
        let header = NSMenuItem(title: "AgentRunner v\(appVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // 업데이트 상태 (동적)
        updateStatusItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateStatusItem.target = self
        menu.addItem(updateStatusItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at login (toggle)
        launchAtLoginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        addAction("Animation Guide…",       #selector(openAnimationGuide(_:)))
        addAction("Open Providers Config…", #selector(openProvidersConfig(_:)))
        addAction("Reload Providers",       #selector(reloadProviders(_:)), key: "r")

        menu.addItem(NSMenuItem.separator())

        addAction("About AgentRunner", #selector(openAbout(_:)))

        menu.addItem(NSMenuItem.separator())

        addAction("Quit AgentRunner", #selector(terminateApp(_:)), key: "q")

        refreshUpdateMenuItem()
    }

    private func addAction(_ title: String, _ selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            popover.toggle(relativeTo: sender)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 메뉴 열 때 launch-at-login 상태 + update TTL 체크
        launchAtLoginItem.state = LoginItem.isEnabled ? .on : .off
        let stale = Date().timeIntervalSince(lastUpdateCheck) >= updateCheckTTL
        if stale, case .checking = updateState {
            // 이미 체크 중 — skip
        } else if stale {
            Task { await self.runUpdateCheck() }
        }
        refreshUpdateMenuItem()
    }

    // MARK: - Update flow

    private func runUpdateCheck() async {
        await MainActor.run {
            self.updateState = .checking
            self.refreshUpdateMenuItem()
        }
        let result = await UpdateChecker.check()
        await MainActor.run {
            switch result {
            case .upToDate:
                self.updateState = .latest
            case .available(let latest, _, let dl, _):
                self.updateState = .available(version: latest, url: dl)
            case .error(let msg):
                self.updateState = .error(msg)
            }
            self.lastUpdateCheck = Date()
            self.refreshUpdateMenuItem()
        }
    }

    private func refreshUpdateMenuItem() {
        guard let item = updateStatusItem else { return }
        // 최신 상태일 땐 메뉴 항목 자체를 숨김 — 알릴 게 있을 때만 노출
        item.isHidden = false
        switch updateState {
        case .idle:
            item.title = "Check for Updates…"
            item.isEnabled = true
        case .checking:
            item.title = "Checking for updates…"
            item.isEnabled = false
        case .latest:
            item.isHidden = true   // 굳이 안 보여줘도 됨
        case .available(let v, _):
            item.title = "⬇ Download v\(v)…"
            item.isEnabled = true
        case .error(let msg):
            item.title = "⚠ Update check failed (\(msg))"
            item.isEnabled = true   // 클릭 시 재시도
        }
    }

    // MARK: - Menu actions

    @objc private func checkForUpdates(_ sender: Any?) {
        if case .available(_, let url) = updateState {
            NSWorkspace.shared.open(url)
            return
        }
        // 강제 재체크
        lastUpdateCheck = .distantPast
        Task { await self.runUpdateCheck() }
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        let target = !LoginItem.isEnabled
        LoginItem.setEnabled(target)
        let actual = LoginItem.isEnabled
        launchAtLoginItem.state = actual ? .on : .off

        // 토글이 의도대로 안 바뀌면 alert (시스템이 차단했거나, Background Items 비활성 등)
        if actual != target {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = """
            macOS may have blocked the change.
            Open System Settings → General → Login Items & Extensions to verify or enable AgentRunner manually.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func openAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openAnimationGuide(_ sender: Any?) {
        if let url = URL(string: "https://github.com/ww-w-ai/AgentRunner#animations") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openProvidersConfig(_ sender: Any?) {
        _ = ProviderRegistry.loadFromFile()
        let url = ProviderRegistry.configURL

        // .jsonc는 macOS에 등록된 기본 핸들러가 없어 "연결된 앱 없음" 다이얼로그가 뜨는 경우가 많음.
        // 1) 먼저 jsonc-aware 에디터(VS Code / Cursor / Sublime) 명시적 시도
        // 2) 실패 시 `open -t`로 시스템 기본 텍스트 에디터 (TextEdit 보장)
        let editorBundleIDs = [
            "com.microsoft.VSCode",       // Visual Studio Code
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.sublimetext.4",          // Sublime Text 4
            "com.sublimetext.3",
            "com.barebones.bbedit",       // BBEdit
        ]
        for bundleID in editorBundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let cfg = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in }
                return
            }
        }

        // 폴백: `open -t` — 시스템 기본 텍스트 에디터로 강제 오픈 (TextEdit always available)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", url.path]
        do {
            try proc.run()
        } catch {
            NSLog("AgentRunner: failed to open providers.jsonc — \(error.localizedDescription)")
        }
    }

    @objc private func reloadProviders(_ sender: Any?) {
        NotificationCenter.default.post(name: .providersChanged, object: nil)
        NSLog("AgentRunner: providers reload triggered (manual)")
    }

    @objc private func terminateApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - Sleep / Wake

    private func registerSleepWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(receiveSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(receiveWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func receiveSleep(_ notification: Notification) {
        NSLog("AgentRunner: system sleep, suspending")
        animator?.stop()
        nettop.stop()
        sessions.stop()
    }

    @objc private func receiveWake(_ notification: Notification) {
        NSLog("AgentRunner: system wake, resuming")
        sessions.start()
        nettop.start()
        animator.renderInitial()
    }
}
