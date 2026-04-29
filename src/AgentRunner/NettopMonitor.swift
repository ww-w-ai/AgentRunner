//
//  NettopMonitor.swift
//  AgentRunner
//

import Foundation

final class NettopMonitor {

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var lineBuffer = Data()
    private var restartAttempts = 0
    private let maxBackoff: TimeInterval = 30.0
    private var isShuttingDown = false

    let parser = NettopParser()

    var onEvent: ((NettopEvent) -> Void)?

    func start() {
        // Blocklist 콜백 주입 → 파서 진입에서 즉시 short-circuit
        parser.isProcessBlocked = { Blocklist.isBlocked($0) }
        spawnNettop()
    }

    func stop() {
        isShuttingDown = true

        // 1) terminationHandler 무력화 — 종료 시 scheduleRestart 자동 발화 방지 (race fix).
        //    sleep/wake 시 stop() → start() 사이클에서 옛 process의 핸들러가 새 process 띄우는 중복 spawn 차단.
        process?.terminationHandler = nil

        // 2) readabilityHandler 해제 + FD 명시적 close (FD leak 방지)
        if let pipe = stdoutPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }

        // 3) SIGTERM 보내고 짧게 대기 — orphan 방지 (SIGKILL fallback 0.5s)
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(0.5)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }

        process = nil
        stdoutPipe = nil
    }

    private func spawnNettop() {
        guard !isShuttingDown else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -s 2: 2초마다 스냅샷 (1초 → 2초로 파싱 부하 절반).
        // 활동 게이지 업데이트 granularity는 충분하고 CPU 절감 큼.
        proc.arguments = ["-L", "0", "-t", "external", "-x", "-s", "2"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.processIncoming(data)
        }

        proc.terminationHandler = { [weak self] terminated in
            NSLog("AgentRunner: nettop exited code=\(terminated.terminationStatus)")
            self?.scheduleRestart()
        }

        do {
            try proc.run()
            self.process = proc
            self.stdoutPipe = pipe
            self.restartAttempts = 0
            NSLog("AgentRunner: nettop spawned pid=\(proc.processIdentifier)")
        } catch {
            NSLog("AgentRunner: failed to spawn nettop: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard !isShuttingDown else { return }
        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts - 1)), maxBackoff)
        NSLog("AgentRunner: restarting nettop in \(delay)s (attempt \(restartAttempts))")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.spawnNettop()
        }
    }

    private func processIncoming(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.prefix(upTo: nl)
            lineBuffer.removeSubrange(...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            if let event = parser.parse(line) {
                onEvent?(event)
            }
        }
    }
}
