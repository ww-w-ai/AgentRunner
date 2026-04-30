//
//  NettopParser.swift
//  AgentRunner
//
//  nettop -x CSV 라인을 NettopEvent로 변환.
//  라인 종류:
//    헤더:        "time,,interface,state,bytes_in,bytes_out,..."
//    프로세스:    "22:47:46.196311,GitHub Desktop .1078,,,4019,3101,..."
//    연결:        "22:47:46.195653,tcp4 192.168.0.197:49180<->160.79.104.10:443,en0,Established,4958,6113,..."
//

import Foundation

final class NettopParser {

    /// 컬럼 인덱스 (헤더 보고 동적 매핑). 못 찾으면 기본값 사용.
    private var idxBytesIn = 4
    private var idxBytesOut = 5
    private var idxState = 3

    /// 직전 process가 블록 대상이면 그 process의 모든 connection 라인을 빠르게 skip.
    /// (component-split + IP 파싱 자체를 회피 — 가장 큰 hot path 절감)
    private var skipUntilNextProcess = false

    /// process 이름이 블록 대상인지 판정. nil이면 모든 process 허용.
    var isProcessBlocked: ((String) -> Bool)?

    /// 한 줄 파싱. nil이면 무시(헤더, 빈 줄, 알 수 없는 형식).
    func parse(_ line: String) -> NettopEvent? {
        // Fast-path: 블록된 process의 connection 라인은 split도 안 함
        // (라인 시작 4글자만 보면 proto 라인인지 알 수 있음)
        if skipUntilNextProcess {
            if line.hasPrefix("tcp") || line.hasPrefix("udp") || line.contains(",tcp") || line.contains(",udp") {
                return nil
            }
        }

        let cols = line.components(separatedBy: ",")
        guard cols.count >= 6 else { return nil }

        // 헤더 라인 감지: 첫 컬럼이 "time"
        if cols[0] == "time" {
            updateColumnIndices(cols)
            return nil
        }

        let nameField = cols[1]

        // 연결 라인: "tcp4 src:port<->dst:port" 형태
        if let proto = detectProto(nameField) {
            if skipUntilNextProcess { return nil }
            return parseConnection(proto: proto, cols: cols)
        }

        // 프로세스 헤더 라인: "name.PID" 형태 (마지막 segment가 숫자)
        if let (name, pid) = parseProcess(nameField) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            skipUntilNextProcess = isProcessBlocked?(trimmed) ?? false
            return .process(name: name, pid: pid)
        }

        return nil
    }

    private func updateColumnIndices(_ cols: [String]) {
        for (i, name) in cols.enumerated() {
            switch name {
            case "bytes_in":  idxBytesIn = i
            case "bytes_out": idxBytesOut = i
            case "state":     idxState = i
            default: break
            }
        }
    }

    private func detectProto(_ field: String) -> String? {
        for proto in ["tcp4", "tcp6", "udp4", "udp6"] {
            if field.hasPrefix(proto + " ") { return proto }
        }
        return nil
    }

    private func parseConnection(proto: String, cols: [String]) -> NettopEvent? {
        let nameField = cols[1]
        // "tcp4 192.168.0.197:49180<->160.79.104.10:443"
        let parts = nameField.dropFirst(proto.count + 1)  // "192...<->160..."
        let endpoints = parts.components(separatedBy: "<->")
        guard endpoints.count == 2 else { return nil }

        guard let (srcIP, srcPort) = splitHostPort(endpoints[0], proto: proto),
              let (dstIP, dstPort) = splitHostPort(endpoints[1], proto: proto) else {
            return nil
        }

        let state = cols.indices.contains(idxState) ? cols[idxState] : ""
        let bytesIn  = UInt64(cols.indices.contains(idxBytesIn)  ? cols[idxBytesIn]  : "") ?? 0
        let bytesOut = UInt64(cols.indices.contains(idxBytesOut) ? cols[idxBytesOut] : "") ?? 0

        return .connection(
            proto: proto, srcIP: srcIP, srcPort: srcPort,
            dstIP: dstIP, dstPort: dstPort, state: state,
            bytesIn: bytesIn, bytesOut: bytesOut
        )
    }

    private func splitHostPort(_ s: String, proto: String) -> (host: String, port: Int)? {
        // nettop 표기 (대괄호 안 씀):
        //   tcp4/udp4 → "1.2.3.4:443" 또는 "host.com:443"  (포트는 ':' 뒤)
        //   tcp6/udp6 → "2607:6bc0::10.443" 또는 "host.com.443" (포트는 마지막 '.' 뒤)
        let isV6 = proto.hasSuffix("6")
        let sepIdx: String.Index?
        if isV6 {
            sepIdx = s.lastIndex(of: ".")
        } else {
            sepIdx = s.lastIndex(of: ":")
        }
        guard let idx = sepIdx else { return nil }
        let hostPart = s[..<idx]
        let portPart = s[s.index(after: idx)...]
        // 와일드카드 포트("*") 제외
        guard let port = Int(portPart) else { return nil }
        var host = String(hostPart)
        // 혹시 모를 IPv6 대괄호 표기 호환
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host, port)
    }

    private func parseProcess(_ field: String) -> (name: String, pid: Int32)? {
        // "GitHub Desktop .1078" → ("GitHub Desktop ", 1078)
        // 마지막 '.' 이후가 숫자면 PID
        guard let dotIdx = field.lastIndex(of: ".") else { return nil }
        let pidPart = field[field.index(after: dotIdx)...]
        guard let pid = Int32(pidPart) else { return nil }
        let name = String(field[..<dotIdx])
        return (name, pid)
    }
}
