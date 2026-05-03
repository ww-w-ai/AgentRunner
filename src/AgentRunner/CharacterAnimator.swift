//
//  CharacterAnimator.swift
//  AgentRunner
//
//  상태(SessionState)와 애니메이션(AnimID)을 분리한 단일-진입점 설계.
//
//  핵심 원칙:
//   1. 애니메이션은 `play(anim)` 단일 함수로만 시작.
//   2. One-shot 애니메이션(jump/three-hit/supreme/tooling-wrap-up)은
//      한번 발동하면 절대 중간에 잘리지 않음. state 변경은 무시되고,
//      애니 종료 시점에 현재 state를 보고 다음 애니를 결정한다.
//   3. Loop 애니메이션(idle/rest/scout/run)은 state 전환 시 즉시 교체 가능.
//      단, idle→running 같은 특정 트랜지션은 one-shot(jump)을 먼저 끼움.
//   4. comboFrames 같은 이중 트랙 제거 — currentFrames 하나만 사용.
//

import Cocoa

final class CharacterAnimator {

    // MARK: - Animation taxonomy

    enum AnimID {
        // Loop (state-driven, can be replaced on state change)
        case idle, rest, scout, run
        // One-shot (uninterruptible, plays to completion)
        case jump, threeHit, supreme, toolingWrapUp

        var isOneShot: Bool {
            switch self {
            case .jump, .threeHit, .supreme, .toolingWrapUp: return true
            case .idle, .rest, .scout, .run: return false
            }
        }
    }

    // MARK: - Stored properties

    private let statusItem: NSStatusItem

    // Session state (driven by Session aggregate)
    private var state: SessionState = .idle
    private var rate: Double = 0

    // Current animation playback
    private var currentAnim: AnimID = .idle
    private var currentFrames: [NSImage] = []
    private var currentInterval: TimeInterval = 0.5
    private var frameIdx: Int = 0
    private var frameTimer: Timer?

    // Combo timing — cumulative active running duration
    private var activeSinceForCombo: Date = .distantPast
    private var lastComboAttempt: Date = .distantPast

    // Idle → rest transition
    private var idleSince: Date = .distantPast

    // MARK: - Tuning

    private let restAfterIdle: TimeInterval = 30                 // idle 30s+ → rest
    private let comboMinRunningDuration: TimeInterval = 10        // 10s running → first combo
    private let comboCheckInterval: TimeInterval = 10             // every 10s after
    private let supremeProbability: Double = 0.25                 // 25% supreme, 75% three-hit
    private let actionMinDuration: TimeInterval = 3.0             // pad short combos

    // Frame intervals
    private let comboFrameInterval: TimeInterval = 0.10
    private let ultimateFrameInterval: TimeInterval = 0.12
    private let jumpFrameInterval: TimeInterval = 0.167
    private let toolingFrameInterval: TimeInterval = 0.25

    // MARK: - Init / lifecycle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func renderInitial() {
        idleSince = Date()
        play(.idle)
        updateLabel(AggregateState(state: .idle, bytesInRate: 0, sessionCount: 0))
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    // MARK: - Public input: state aggregate

    /// 외부(SessionManager)에서 호출. 상태 변경을 흡수하고 적절히 애니 전환.
    /// One-shot이 진행 중이면 상태만 갱신하고 rendering은 건드리지 않는다.
    func render(_ agg: AggregateState) {
        let oldState = state
        state = agg.state
        rate = agg.bytesInRate

        // 상태 진입 시점 추적 (애니 결정과 무관 — 항상 갱신)
        if oldState != .running && state == .running {
            activeSinceForCombo = Date()
            lastComboAttempt = Date()
        }
        if state == .idle {
            if oldState != .idle { idleSince = Date() }
        } else {
            idleSince = .distantPast
        }

        updateLabel(agg)

        // One-shot 진행 중이면 절대 인터럽트하지 않음.
        // 끝날 때 onAnimationComplete()가 현재 state를 보고 다음 애니 결정.
        if currentAnim.isOneShot { return }

        // Loop 애니메이션 진행 중 — state 전환 시 즉시 교체.
        let stateChanged = oldState != state
        if stateChanged {
            // idle → running: 점프 one-shot을 끼워 시각적 강조
            if oldState == .idle && state == .running {
                play(.jump)
                return
            }
            // X → tooling: wrap-up one-shot
            if state == .tooling {
                play(.toolingWrapUp)
                return
            }
            // 그 외: 새 loop으로 즉시 전환
            play(decideLoop())
            return
        }

        // 같은 state — running speed가 rate에 따라 바뀔 수 있으므로 interval 갱신
        if currentAnim == .run {
            let newInterval = intervalFor(.run)
            if abs(newInterval - currentInterval) > 0.05 {
                currentInterval = newInterval
                restartTimer()
            }
        }
    }

    // MARK: - Animation core (single entry point)

    /// 애니메이션을 시작. 모든 애니 전환은 이 함수를 거친다.
    private func play(_ anim: AnimID) {
        currentAnim = anim
        currentFrames = framesFor(anim)
        currentInterval = intervalFor(anim)
        frameIdx = 0
        renderCurrentFrame()
        restartTimer()

        // 애니 시작 시 부수 효과 (콤보 카운터 보정 등)
        switch anim {
        case .jump:
            // 점프 시간만큼 콤보 카운트 시작점을 미래로 밀어 — 점프 끝에서 10s 카운트 시작
            let dur = TimeInterval(currentFrames.count) * currentInterval
            activeSinceForCombo = Date().addingTimeInterval(dur)
            lastComboAttempt = activeSinceForCombo
#if DEBUG
        case .threeHit:
            NSLog("AgentRunner: ▶︎ three-hit (frames=\(currentFrames.count), interval=\(Int(currentInterval*1000))ms)")
        case .supreme:
            NSLog("AgentRunner: ⚡️ supreme (frames=\(currentFrames.count), interval=\(Int(currentInterval*1000))ms)")
        case .toolingWrapUp:
            NSLog("AgentRunner: 🔧 tooling wrap-up (frames=\(currentFrames.count))")
#endif
        default:
            break
        }
    }

    /// 현재 state에 적합한 loop 애니를 결정.
    private func decideLoop() -> AnimID {
        switch state {
        case .running: return .run
        case .scout:   return .scout
        case .tooling: return .idle  // tooling은 항상 one-shot으로만 진입 — fallback
        case .idle:
            if idleSince != .distantPast,
               Date().timeIntervalSince(idleSince) >= restAfterIdle {
                return .rest
            }
            return .idle
        }
    }

    // MARK: - Frame timer

    private func restartTimer() {
        frameTimer?.invalidate()
        guard currentInterval > 0 else { return }
        let timer = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        frameIdx += 1
        if frameIdx < currentFrames.count {
            renderCurrentFrame()
            return
        }

        // 사이클 끝 (마지막 프레임 다 그렸음)
        if currentAnim.isOneShot {
            onAnimationComplete()
            return
        }

        // Loop: 처음으로 wrap, transition 체크
        frameIdx = 0

        // 1. RUN 사이클 끝 → 콤보 발동 시도
        if currentAnim == .run, tryFireCombo() {
            return  // 콤보가 새 애니로 전환했음
        }

        // 2. IDLE 사이클 끝 → rest 전환 체크
        if currentAnim == .idle,
           idleSince != .distantPast,
           Date().timeIntervalSince(idleSince) >= restAfterIdle {
            play(.rest)
            return
        }

        renderCurrentFrame()
    }

    /// One-shot 종료 시 호출. 현재 state를 보고 다음 애니를 결정한다.
    private func onAnimationComplete() {
        // tooling-wrap-up 종료 → idle frame 강제 (Session이 아직 tooling이어도 dig 무한 루프 방지)
        if currentAnim == .toolingWrapUp {
            play(.idle)
            return
        }

        // jump / three-hit / supreme — 현재 state에 맞는 loop으로 복귀
        // 단, state가 .tooling이면 wrap-up을 곧바로 시작
        if state == .tooling {
            play(.toolingWrapUp)
            return
        }
        play(decideLoop())
    }

    // MARK: - Combo trigger (only at run-loop boundary)

    /// run 사이클 끝마다 호출. 콤보 조건 만족 시 새 애니로 전환하고 true 반환.
    private func tryFireCombo() -> Bool {
        guard state == .running else { return false }
        let now = Date()
        let activeDur = now.timeIntervalSince(activeSinceForCombo)
        let sinceLast = now.timeIntervalSince(lastComboAttempt)
        guard activeDur >= comboMinRunningDuration else { return false }
        guard sinceLast >= comboCheckInterval else { return false }

        lastComboAttempt = now
        let roll = Double.random(in: 0..<1)
        play(roll < supremeProbability ? .supreme : .threeHit)
        return true
    }

    // MARK: - Rendering

    private func renderCurrentFrame() {
        guard let button = statusItem.button else { return }
        guard !currentFrames.isEmpty else { return }
        let img = currentFrames[frameIdx % currentFrames.count]
        if button.image !== img {
            button.image = img
        }
    }

    // MARK: - Label (popover hint)

    private func updateLabel(_ agg: AggregateState) {
        guard let button = statusItem.button else { return }

        let stateLabel: String
        switch agg.state {
        case .idle:    stateLabel = "idle"
        case .scout:   stateLabel = "scout"
        case .running: stateLabel = "running"
        case .tooling: stateLabel = "tooling"
        }

        button.title = agg.sessionCount >= 2 ? "·\(agg.sessionCount)" : ""
        button.toolTip = """
        AgentRunner — \(stateLabel)
        \(agg.sessionCount) session(s)
        \(formatRate(agg.bytesInRate))
        """
    }

    // MARK: - Frame data + intervals

    private static var cache: [String: NSImage] = [:]

    /// AnimID → 프레임 시퀀스. one-shot은 padding(extendToMinDuration)이 미리 적용된 결과.
    private func framesFor(_ anim: AnimID) -> [NSImage] {
        switch anim {
        case .idle:    return loadFrames(prefix: "runner_idle",  count: 4)
        case .rest:    return loadFrames(prefix: "runner_rest",  count: 2)
        case .scout:   return loadFrames(prefix: "runner_climb", count: 4)
        case .run:     return loadFrames(prefix: "runner_run",   count: 6)
        case .jump:
            // jump(4) + hold cycles(10 = 5x2) + fall(2) = 16 frames @ 167ms ≈ 2.67s
            // hold 1.67s → 공중에서 충분히 떠 있는 느낌
            let jump = loadFrames(prefix: "runner_trick_jump",        count: 4)
            let hold = loadFrames(prefix: "runner_trick_jump_hold",   count: 2)
            let fall = loadFrames(prefix: "runner_trick_jump_fall",   count: 2)
            var seq = jump
            for _ in 0..<5 { seq.append(contentsOf: hold) }
            seq.append(contentsOf: fall)
            return seq
        case .threeHit:
            let base = loadFrames(prefix: "runner_combo_3hit", count: 17)
            return extendToMinDuration(frames: base, interval: comboFrameInterval)
        case .supreme:
            let base = loadFrames(prefix: "runner_ultimate_supreme", count: 25)
            // 마지막 프레임 8회 hold (≈1s) — 임팩트
            var seq = base
            if let last = base.last { for _ in 0..<8 { seq.append(last) } }
            return extendToMinDuration(frames: seq, interval: ultimateFrameInterval)
        case .toolingWrapUp:
            // draw(4) + hold middle 8 (2s) + sheath(4) = 16 frames @ 250ms = 4s
            let base = loadFrames(prefix: "runner_dig", count: 8)
            guard base.count == 8 else { return base }
            var seq: [NSImage] = []
            seq.append(contentsOf: base.prefix(4))
            for _ in 0..<8 { seq.append(base[3]) }
            seq.append(contentsOf: base.suffix(4))
            return seq
        }
    }

    private func intervalFor(_ anim: AnimID) -> TimeInterval {
        switch anim {
        case .idle:           return 0.25
        case .rest:           return 2.5    // 매우 천천히 (5s 풀 사이클)
        case .scout:          return 0.30
        case .run:            return CharacterAnimator.runIntervalForRate(rate)
        case .jump:           return jumpFrameInterval
        case .threeHit:       return comboFrameInterval
        case .supreme:        return ultimateFrameInterval
        case .toolingWrapUp:  return toolingFrameInterval
        }
    }

    /// RUNNING 속도 = bytes_in_rate에 비례 (로그 스케일).
    /// 50 B/s 이하 = 350ms (느린 걷기), 50 KB/s 이상 = 50ms (질주).
    internal static func runIntervalForRate(_ r: Double) -> TimeInterval {
        let floor: Double = 50
        let r = max(floor, r)
        let logR = log10(r)             // 50 → 1.7, 50000 → 4.7
        let normalized = max(0, min(1, (logR - 1.7) / 3.0))
        let ms = 350 - (normalized * 300)
        return TimeInterval(ms / 1000.0)
    }

    /// 짧은 one-shot을 actionMinDuration 이상으로 padding (마지막 프레임 hold).
    private func extendToMinDuration(frames: [NSImage], interval: TimeInterval) -> [NSImage] {
        let natural = TimeInterval(frames.count) * interval
        guard natural < actionMinDuration, let last = frames.last else { return frames }
        let needed = Int(ceil((actionMinDuration - natural) / interval))
        return frames + Array(repeating: last, count: needed)
    }

    private func loadFrames(prefix: String, count: Int) -> [NSImage] {
        return (0..<count).compactMap { i in
            let key = "\(prefix)_\(i)"
            if let cached = Self.cache[key] { return cached }
            guard let img = NSImage(named: key) else {
                NSLog("AgentRunner: missing asset \(key)")
                return nil
            }
            Self.cache[key] = img
            return img
        }
    }

    private func formatRate(_ b: Double) -> String {
        if b < 1024 { return String(format: "%.0fB/s", b) }
        if b < 1024 * 1024 { return String(format: "%.1fKB/s", b / 1024) }
        return String(format: "%.1fMB/s", b / 1024 / 1024)
    }
}
