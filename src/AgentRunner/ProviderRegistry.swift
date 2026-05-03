//
//  ProviderRegistry.swift
//  AgentRunner
//
//  AI provider 호스트 → IP 캐시.
//  설정은 ~/Library/Application Support/AgentRunner/providers.jsonc 텍스트 파일.
//  파워유저가 직접 편집 → 메뉴의 "Reload Providers"로 즉시 반영.
//

import Foundation
import Network

struct Provider: Codable, Identifiable {
    let name: String
    var hosts: [String]
    var enabled: Bool = true
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, hosts, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        hosts = try c.decode([String].self, forKey: .hosts)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    init(name: String, hosts: [String], enabled: Bool = true) {
        self.name = name; self.hosts = hosts; self.enabled = enabled
    }
}

private struct ProvidersFile: Codable {
    var providers: [Provider]
}

extension Notification.Name {
    static let providersChanged = Notification.Name("providersChanged")
}

final class ProviderRegistry {

    /// 첫 실행 시 작성될 시드 — 사용자 편집 가능.
    static let seedProviders: [Provider] = [
        Provider(name: "Anthropic", hosts: ["api.anthropic.com"]),
        Provider(name: "OpenAI",    hosts: ["api.openai.com"]),
        Provider(name: "Google",    hosts: ["generativelanguage.googleapis.com",
                                            "aiplatform.googleapis.com"]),
        Provider(name: "OpenRouter",hosts: ["openrouter.ai"]),
        Provider(name: "xAI",       hosts: ["api.x.ai"]),
        Provider(name: "DeepSeek",  hosts: ["api.deepseek.com"]),
        Provider(name: "Cohere",    hosts: ["api.cohere.com"]),
        Provider(name: "Mistral",   hosts: ["api.mistral.ai"]),
        Provider(name: "Groq",      hosts: ["api.groq.com"]),
        Provider(name: "Together",  hosts: ["api.together.xyz"]),
        Provider(name: "Perplexity",hosts: ["api.perplexity.ai"]),
    ]

    /// 설정 파일 경로
    static var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AgentRunner", isDirectory: true)
        return dir.appendingPathComponent("providers.jsonc")
    }

    /// v1.0 오타본(`providers.jsoncc`) — 기존 사용자 마이그레이션용
    private static var legacyConfigURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AgentRunner", isDirectory: true)
        return dir.appendingPathComponent("providers.jsoncc")
    }

    /// IP 캐시 영속화 경로. 콜드스타트 시 기존에 본 IP 풀을 즉시 복원해
    /// CDN 회전으로 인한 신규 세션 미스를 줄인다.
    static var cacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AgentRunner", isDirectory: true)
        return dir.appendingPathComponent("ip_cache.json")
    }

    /// 파일에서 로드. 없으면 시드로 초기화. JSONC(주석/trailing comma 허용) 지원.
    static func loadFromFile() -> [Provider] {
        let url = configURL
        let fm = FileManager.default

        // v1.0에서 .jsoncc로 잘못 저장된 파일이 있으면 .jsonc로 자동 이전
        if !fm.fileExists(atPath: url.path),
           fm.fileExists(atPath: legacyConfigURL.path) {
            do {
                try fm.moveItem(at: legacyConfigURL, to: url)
                NSLog("AgentRunner: migrated providers.jsoncc → providers.jsonc")
            } catch {
                NSLog("AgentRunner: legacy file migration failed — \(error.localizedDescription)")
            }
        }

        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            writeSeedFile()
            return seedProviders
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let stripped = JSONC.strip(raw)
            let data = Data(stripped.utf8)
            let decoded = try JSONDecoder().decode(ProvidersFile.self, from: data)
            return decoded.providers
        } catch {
            NSLog("AgentRunner: providers.jsonc parse error — \(error.localizedDescription). Using seeds.")
            return seedProviders
        }
    }

    /// 첫 실행 시 작성하는 시드 파일 (가이드 주석 포함).
    @discardableResult
    static func writeSeedFile() -> Bool {
        let header = """
        // AgentRunner Providers Configuration
        //
        // Edit this file to add custom providers or disable defaults.
        // After saving, use the menu: "Reload Providers" (⌘R).
        //
        // RULES:
        //   - To disable a provider: comment out its line with "//"
        //   - To add custom: append a new {...} entry to "providers"
        //   - Comments (// and /* ... */) and trailing commas are allowed (JSONC)
        //   - Hosts must be FQDN (e.g., api.foo.com); port and path are stripped
        //
        // EXAMPLE:
        //   {"name": "MyClaude", "hosts": ["api.example.com"]}
        //
        """
        let bodyLines = seedProviders.map { p -> String in
            let hostsJson = p.hosts.map { "\"\($0)\"" }.joined(separator: ", ")
            return "    {\"name\": \"\(p.name)\", \"hosts\": [\(hostsJson)]}"
        }.joined(separator: ",\n")
        let body = """
        {
          "providers": [
        \(bodyLines)
          ]
        }
        """
        let content = header + "\n" + body + "\n"
        do {
            try content.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("AgentRunner: providers.jsonc write error — \(error.localizedDescription)")
            return false
        }
    }

    static func effectiveProviders() -> [Provider] {
        loadFromFile().filter { $0.enabled }
    }

    // MARK: - Instance state

    /// Fast 모드: 신규 IP 풀을 빠르게 학습하는 단계 (1분 간격).
    /// Slow 모드: 안정 운영 단계 (10분 간격). CPU/배터리 절약.
    private let fastRefreshInterval: TimeInterval = 60
    private let slowRefreshInterval: TimeInterval = 600
    private let entryTTL: TimeInterval = 90 * 24 * 3600   // 90일 — 한 번 본 IP는 이 기간 동안 유효

    /// 첫 설치/리셋 후 누적 60분 도달 전: 매 실행 시 fast 60분 → slow.
    /// 그 이후엔 매 실행 시 fast 10분(warm-up) → slow.
    private let initialFastBudgetSeconds: TimeInterval = 3600   // 신규 앱 1시간
    private let warmupFastBudgetSeconds: TimeInterval = 600     // 성숙 앱 10분 워밍업
    private let maturityThresholdMinutes: Double = 60.0

    /// UserDefaults 키 — 누적 실행시간(분 단위, fast +1, slow +10).
    /// 디버깅: `defaults read <bundle> AgentRunner.cumulativeRefreshMinutes`
    private static let cumulativeMinutesKey = "AgentRunner.cumulativeRefreshMinutes"

    /// 이번 세션의 fast 예산. start() 시점에 누적값에 따라 결정.
    private var sessionFastBudgetSeconds: TimeInterval = 0
    private var sessionFastElapsedSeconds: TimeInterval = 0

    private struct Entry: Codable { let provider: String; var expiresAt: Date }
    private var ipToProvider: [String: Entry] = [:]
    private static let saveDebounceQueue = DispatchQueue(label: "AgentRunner.cacheSave", qos: .utility)
    private let lock = NSLock()
    private var refreshTimer: DispatchSourceTimer?
    private var changeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "AgentRunner.pathMonitor")
    private var pathRefreshWorkItem: DispatchWorkItem?
    private var hasReceivedInitialPath = false

    /// 마지막으로 관측된 네트워크 도달성. 첫 업데이트 전에는 true (낙관적 가정).
    private(set) var isOnline: Bool = true

    func start() {
        loadCacheFromDisk()
        let cumulative = UserDefaults.standard.double(forKey: Self.cumulativeMinutesKey)
        sessionFastBudgetSeconds = cumulative < maturityThresholdMinutes
            ? initialFastBudgetSeconds : warmupFastBudgetSeconds
        sessionFastElapsedSeconds = 0
        NSLog("AgentRunner: refresh schedule — cumulative=\(Int(cumulative))min, fast budget=\(Int(sessionFastBudgetSeconds))s")
        refreshNow()
        scheduleRefresh()
        startPathMonitor()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .providersChanged, object: nil, queue: nil
        ) { [weak self] _ in self?.refreshNow() }
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathRefreshWorkItem?.cancel()
        pathRefreshWorkItem = nil
        hasReceivedInitialPath = false
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
            changeObserver = nil
        }
    }

    /// External trigger (e.g. system wake) — re-resolve immediately.
    func refresh() {
        refreshNow()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.isOnline = (path.status == .satisfied)
            // Skip the initial delivery; start() already kicked off refreshNow().
            guard self.hasReceivedInitialPath else {
                self.hasReceivedInitialPath = true
                return
            }
            // Coalesce rapid flips (e.g. VPN bring-up) into a single refresh.
            self.pathRefreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                NSLog("AgentRunner: network path changed, refreshing IPs")
                self?.refreshNow()
            }
            self.pathRefreshWorkItem = work
            DispatchQueue.global(qos: .background)
                .asyncAfter(deadline: .now() + 1.0, execute: work)
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    /// Test helper: inject a static IP→provider mapping with a far-future expiry.
    /// Internal access only — used by AgentRunnerTests via @testable import.
    internal func testInjectStaticMapping(_ map: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        let farFuture = Date.distantFuture
        for (ip, name) in map {
            ipToProvider[ip] = Entry(provider: name, expiresAt: farFuture)
        }
    }

    func providerName(forIP ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = ipToProvider[ip] else { return nil }
        if entry.expiresAt < Date() {
            ipToProvider.removeValue(forKey: ip)
            return nil
        }
        return entry.provider
    }

    private func scheduleRefresh() {
        let interval = currentRefreshInterval()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.handleRefreshTick() }
        timer.resume()
        refreshTimer = timer
    }

    private func currentRefreshInterval() -> TimeInterval {
        return sessionFastElapsedSeconds < sessionFastBudgetSeconds
            ? fastRefreshInterval : slowRefreshInterval
    }

    /// 매 틱마다 누적/세션 카운터 업데이트 후 dig 실행. fast→slow 전환 시점에
    /// 타이머 재스케줄.
    private func handleRefreshTick() {
        let interval = currentRefreshInterval()
        let isFast = (interval == fastRefreshInterval)
        let increment = isFast ? 1.0 : 10.0
        let prev = UserDefaults.standard.double(forKey: Self.cumulativeMinutesKey)
        UserDefaults.standard.set(prev + increment, forKey: Self.cumulativeMinutesKey)

        if isFast {
            sessionFastElapsedSeconds += fastRefreshInterval
            if sessionFastElapsedSeconds >= sessionFastBudgetSeconds {
                NSLog("AgentRunner: fast budget exhausted — switching to slow (10m)")
                refreshTimer?.cancel()
                refreshTimer = nil
                scheduleRefresh()
            }
        }
        refreshNow()
    }

    private func refreshNow() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let newExpiry = now.addingTimeInterval(self.entryTTL)
            var freshSeen: [(ip: String, provider: String)] = []
            for provider in Self.effectiveProviders() {
                for host in provider.hosts {
                    for ip in self.resolve(host) {
                        freshSeen.append((ip, provider.name))
                    }
                }
            }
            self.lock.lock()
            // 만료된 엔트리 제거
            self.ipToProvider = self.ipToProvider.filter { $0.value.expiresAt >= now }
            // 이번에 본 IP는 추가하거나 만료시각 갱신 (누적)
            for (ip, name) in freshSeen {
                if var existing = self.ipToProvider[ip] {
                    existing.expiresAt = newExpiry
                    self.ipToProvider[ip] = existing
                } else {
                    self.ipToProvider[ip] = Entry(provider: name, expiresAt: newExpiry)
                }
            }
            let total = self.ipToProvider.count
            let snapshot = self.ipToProvider
            self.lock.unlock()
            NSLog("AgentRunner: providers refreshed, \(freshSeen.count) resolved, \(total) IPs cached")
            self.saveCacheToDisk(snapshot)
        }
    }

    private func loadCacheFromDisk() {
        let url = Self.cacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: Entry].self, from: data)
            let now = Date()
            let live = decoded.filter { $0.value.expiresAt >= now }
            lock.lock()
            ipToProvider = live
            lock.unlock()
            NSLog("AgentRunner: IP cache hydrated from disk — \(live.count) live (\(decoded.count - live.count) expired)")
        } catch {
            NSLog("AgentRunner: IP cache read error — \(error.localizedDescription). Starting empty.")
        }
    }

    private func saveCacheToDisk(_ snapshot: [String: Entry]) {
        Self.saveDebounceQueue.async {
            // 매 refresh마다 timestamp가 갱신되므로 dedup 없이 항상 저장.
            // 페이로드 < 100KB, 인터벌도 1~10분이라 부담 무시 가능.
            let url = Self.cacheURL
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                let tmp = url.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                _ = try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch {
                NSLog("AgentRunner: IP cache write error — \(error.localizedDescription)")
            }
        }
    }

    private func resolve(_ host: String) -> [String] {
        let pureHost: String = {
            if let colon = host.firstIndex(of: ":") { return String(host[..<colon]) }
            return host
        }()
        // dig 기본은 A(IPv4)만 반환. macOS가 IPv6로 routing할 때 매칭이 0이 돼 망가지므로
        // A와 AAAA를 모두 조회한다. (Claude Code → api.anthropic.com 트래픽은 IPv6로 나감)
        return digQuery(pureHost, type: "A") + digQuery(pureHost, type: "AAAA")
    }

    private func digQuery(_ host: String, type: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        proc.arguments = ["+short", "+timeout=2", "+tries=1", "-t", type, host]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        return str.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isIPv4($0) || isIPv6($0) }
    }

    private func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private func isIPv6(_ s: String) -> Bool {
        return s.contains(":") && s.allSatisfy { $0.isHexDigit || $0 == ":" }
    }
}
