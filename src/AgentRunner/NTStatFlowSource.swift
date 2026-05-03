//
//  NTStatFlowSource.swift
//  AgentRunner
//
//  Production NetworkFlowSource backed by the macOS private SPI ntstat.
//  Replaces the old nettop subprocess: in-process kernel control socket,
//  push semantics, no CSV pipeline.
//
//  Lifecycle
//  ---------
//  start() opens a socket to com.apple.network.statistics, sends four
//  ADD_ALL_SRCS subscriptions (TCP/UDP × KERNEL/USERLAND), arms a
//  DispatchSourceRead, and starts a 2-second timer that polls the
//  kernel for byte counters via a single GET_UPDATE request.
//
//  stop() is idempotent. After stop() the source can be re-started
//  (sleep/wake support) — internal state is reset on every start().
//

import Darwin
import Foundation

/// Sized to hold a few ntstat messages worth of bytes. A typical
/// SRC_UPDATE for TCP_USERLAND runs ~500 bytes; SO_RCVBUF is set to
/// 256 KB so the kernel can buffer many of these between drains.
private let NTSTAT_READ_BUFFER_SIZE = 64 * 1024

/// CTLIOCGINFO is `_IOWR('N', 3, struct ctl_info)`. Swift can't import
/// macros that compute on a sizeof, so we hand-evaluate it. Encoding:
///   IOC_INOUT (0xC0000000) | ((sizeof(ctl_info) & 0x1FFF) << 16)
///       | ('N' << 8) | 3
/// sizeof(ctl_info) = 4 (u_int32_t ctl_id) + 96 (char[96]) = 100.
private let CTLIOCGINFO: UInt = 0xC064_4E03

/// How often we poll the kernel for fresh counters. Matches the
/// SessionManager publish tick so per-flow rates align with the
/// existing 2-second-window state-machine semantics.
private let NTSTAT_UPDATE_POLL_INTERVAL: TimeInterval = 2.0

// libproc.h — pid → process name 안정 API. xnu의 nstat descriptor pname
// 필드가 macOS 빌드에 따라 빈 칸/버전 문자열 등으로 흐트러지는 케이스가
//있어, 이 syscall 한 방으로 우회한다. macOS 13+ 모두 지원.
@_silgen_name("proc_name")
private func proc_name(_ pid: Int32,
                       _ buffer: UnsafeMutableRawPointer,
                       _ buffersize: UInt32) -> Int32

/// pid → process name. 실패 시 nil. 빈 문자열 반환 시에도 nil (descriptor의
/// pname을 fallback으로 쓰게 만들기 위함).
private func resolveProcessName(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 256)
    let n = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
        guard let base = ptr.baseAddress else { return -1 }
        return proc_name(pid, UnsafeMutableRawPointer(base), UInt32(ptr.count))
    }
    guard n > 0 else { return nil }
    let name = String(cString: buf)
    return name.isEmpty ? nil : name
}

final class NTStatFlowSource: NetworkFlowSource {

    private let queue = DispatchQueue(label: "ai.ww-w.AgentRunner.ntstat")

    // Live state — all touched only on `queue`.
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var updateTimer: DispatchSourceTimer?
    private var eventHandler: (@Sendable (NetworkFlowEvent) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var contextCounter: UInt64 = 1
    private var isShuttingDown = false
    /// Reusable receive buffer — allocated once per source lifecycle.
    private var rxBuffer: UnsafeMutableRawPointer?

    /// Tracks which srcref values we've already reported as flowStarted
    /// so a periodic UPDATE doesn't re-emit the start event.
    private var startedFlows: Set<UInt64> = []

    init() {}

    deinit {
        if fd >= 0 { Darwin.close(fd) }
        rxBuffer?.deallocate()
    }

    // MARK: - NetworkFlowSource

    func start(
        eventHandler: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        var setupError: Error?
        queue.sync {
            do {
                try self.setUpLocked(events: eventHandler, failure: failureHandler)
            } catch {
                setupError = error
                self.tearDownLocked()
            }
        }
        if let e = setupError { throw e }
    }

    func stop() {
        queue.sync { self.tearDownLocked() }
    }

    // MARK: - Setup / teardown (queue-confined)

    private func setUpLocked(
        events: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failure: @escaping @Sendable (Error) -> Void
    ) throws {
        isShuttingDown = false
        startedFlows.removeAll(keepingCapacity: true)
        eventHandler = events
        failureHandler = failure

        // 1. Open kernel control socket.
        let s = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard s >= 0 else {
            throw NetworkFlowSourceError.kernelControlUnavailable(errno: errno)
        }

        // 2. Resolve control name to ctl_id.
        var info = ctl_info()
        let nameCapacity = MemoryLayout.size(ofValue: info.ctl_name)
        withUnsafeMutablePointer(to: &info.ctl_name) { ptr in
            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = NSTAT_CONTROL_NAME.withCString { strncpy(buf, $0, nameCapacity) }
        }
        if ioctl(s, CTLIOCGINFO, &info) != 0 {
            let e = errno
            Darwin.close(s)
            throw NetworkFlowSourceError.kernelControlUnavailable(errno: e)
        }

        // 3. Connect to that ctl_id.
        var sc = sockaddr_ctl()
        sc.sc_id = info.ctl_id
        sc.sc_unit = 0
        sc.sc_family = UInt8(AF_SYSTEM)
        sc.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        sc.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        let connectRC = withUnsafePointer(to: &sc) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(s, sap, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        if connectRC != 0 {
            let e = errno
            Darwin.close(s)
            throw NetworkFlowSourceError.kernelControlUnavailable(errno: e)
        }
        fd = s

        // 4. Bump SO_RCVBUF — default ~2 KB triggers ENOBUFS as soon as
        //    the existing flow inventory is dumped on subscribe.
        var rcvbuf: Int32 = 256 * 1024
        _ = setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf,
                       socklen_t(MemoryLayout<Int32>.size))

        // 5. Allocate the lifecycle-scoped receive buffer.
        rxBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: NTSTAT_READ_BUFFER_SIZE, alignment: 8)

        // 6. Subscribe to all four TCP/UDP providers. KERNEL covers
        //    BSD-socket apps (Node, Python, Go binaries — every CLI
        //    agent we care about). USERLAND covers Network-framework /
        //    NWConnection clients. Without KERNEL, agents like Claude
        //    Code (Node) are completely invisible to us.
        try subscribeLocked(provider: .tcpKernel)
        try subscribeLocked(provider: .udpKernel)
        try subscribeLocked(provider: .tcpUserland)
        try subscribeLocked(provider: .udpUserland)

        // 7. Arm read source on the I/O queue.
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainSocket() }
        rs.setCancelHandler { [weak self] in self?.handleSourceCancelled() }
        readSource = rs
        rs.resume()

        // 8. Periodic GET_UPDATE poll. A single message with
        //    srcref=ALL pulls counts for every active source.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + NTSTAT_UPDATE_POLL_INTERVAL,
                   repeating: NTSTAT_UPDATE_POLL_INTERVAL,
                   leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.requestUpdate() }
        updateTimer = t
        t.resume()

        NSLog("AgentRunner: ntstat flow source started fd=\(fd)")
    }

    private func tearDownLocked() {
        isShuttingDown = true
        updateTimer?.cancel(); updateTimer = nil
        readSource?.cancel(); readSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        rxBuffer?.deallocate(); rxBuffer = nil
        eventHandler = nil
        failureHandler = nil
        startedFlows.removeAll(keepingCapacity: false)
    }

    private func handleSourceCancelled() {
        // DispatchSourceRead cancellation is normal during stop().
        // If it fires while not shutting down, the kernel closed our
        // socket — treat that like a runtime failure.
        if !isShuttingDown {
            let h = failureHandler
            tearDownLocked()
            h?(NetworkFlowSourceError.sourceClosed)
        }
    }

    // MARK: - Outbound requests

    private func subscribeLocked(provider: NStatProvider) throws {
        // 디자인 스펙(2026-05-02-ntstat-migration-design.md §11)이 명시한
        // externalProduction 필터:
        //  - acceptCellular | acceptWiFi | acceptWired: 외부 인터페이스만
        //  - useUpdateForAdd: 신규 flow 시 SRC_UPDATE에 descriptor 인라인.
        //    SRC_ADDED→getSrcDesc 라운드트립 race 가능성 제거.
        //  - providerNoZeroDeltas: idle flow의 0-byte chatter 억제.
        var msg = nstat_msg_add_all_srcs()
        msg.hdr.context = nextContext()
        msg.hdr.type = NStatMsgType.addAllSrcs.rawValue
        msg.hdr.length = UInt16(MemoryLayout<nstat_msg_add_all_srcs>.size)
        msg.provider = provider.rawValue
        msg.filter = NStatFilter.externalProduction

        let written = withUnsafeBytes(of: &msg) { buf -> Int in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        if written <= 0 {
            throw NetworkFlowSourceError.subscriptionFailed(errno: errno)
        }
    }

    /// Single GET_UPDATE with srcref=ALL. Kernel responds with one
    /// SRC_UPDATE per active source matching our subscriptions —
    /// including any whose SRC_ADDED we may have missed.
    private func requestUpdate() {
        guard fd >= 0 else { return }
        var msg = nstat_msg_query_src()
        msg.hdr.context = nextContext()
        msg.hdr.type = NStatMsgType.getUpdate.rawValue
        msg.hdr.length = UInt16(MemoryLayout<nstat_msg_query_src>.size)
        msg.srcref = NSTAT_SRC_REF_ALL
        _ = withUnsafeBytes(of: &msg) { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    private func nextContext() -> UInt64 {
        let c = contextCounter
        contextCounter &+= 1
        return c
    }

    // MARK: - Read / decode

    private func drainSocket() {
        guard fd >= 0, let buffer = rxBuffer else { return }
        // SOCK_DGRAM gives one ntstat datagram per recv.
        readLoop: while true {
            let n = Darwin.recv(fd, buffer, NTSTAT_READ_BUFFER_SIZE, MSG_DONTWAIT)
            if n <= 0 {
                if n == 0 || (errno == EAGAIN || errno == EWOULDBLOCK) { break readLoop }
                NSLog("AgentRunner: ntstat recv error errno=\(errno)")
                break readLoop
            }
            decodeChunk(buffer, length: n)
        }
    }

    private func decodeChunk(_ chunk: UnsafeRawPointer, length: Int) {
        var offset = 0
        while offset + 16 <= length {
            let hdrPtr = chunk.advanced(by: offset)
                .assumingMemoryBound(to: nstat_msg_hdr.self)
            let msgLen = Int(hdrPtr.pointee.length)
            let msgType = hdrPtr.pointee.type
            guard msgLen >= 16, offset + msgLen <= length else { return }
            decodeMessage(chunk.advanced(by: offset),
                          length: msgLen, type: msgType)
            offset += msgLen
        }
    }

    private func decodeMessage(_ p: UnsafeRawPointer, length: Int, type: UInt32) {
        guard let kind = NStatMsgType(rawValue: type) else { return }
        switch kind {
        case .srcAdded:                       handleSrcAdded(p, length: length)
        case .srcRemoved:                     handleSrcRemoved(p, length: length)
        case .srcUpdate, .srcExtendedUpdate:  handleSrcUpdate(p, length: length)
        case .srcCounts:                      handleSrcCounts(p, length: length)
        case .srcDesc:                        handleSrcDesc(p, length: length)
        case .error, .success:                break
        default:                              break
        }
    }

    private func handleSrcAdded(_ p: UnsafeRawPointer, length: Int) {
        guard length >= 24 else { return }   // hdr(16) + srcref(8)
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        // Without a descriptor we can't classify the flow yet. Request one.
        var req = nstat_msg_query_src()
        req.hdr.context = nextContext()
        req.hdr.type = NStatMsgType.getSrcDesc.rawValue
        req.hdr.length = UInt16(MemoryLayout<nstat_msg_query_src>.size)
        req.srcref = srcref
        _ = withUnsafeBytes(of: &req) { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    private func handleSrcRemoved(_ p: UnsafeRawPointer, length: Int) {
        guard length >= 24 else { return }
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        if startedFlows.remove(srcref) != nil {
            emit(.flowEnded(flowID: srcref))
        }
    }

    private func handleSrcUpdate(_ p: UnsafeRawPointer, length: Int) {
        // Layout: hdr + srcref + event_flags + counts + provider +
        // reserved[4] + data[].
        guard length >= NSTAT_UPDATE_HEADER_SIZE else { return }
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        // counts.rxbytes / txbytes — second and fourth u64 inside counts.
        let rxbytes = p.load(fromByteOffset: 32 + 8, as: UInt64.self)
        let txbytes = p.load(fromByteOffset: 32 + 24, as: UInt64.self)
        let provider = p.load(fromByteOffset: 144, as: UInt32.self)

        let descBase = NSTAT_UPDATE_HEADER_SIZE
        let descLen  = length - descBase
        if !startedFlows.contains(srcref), descLen > 0 {
            if let desc = makeDescriptor(srcref: srcref, provider: provider,
                                         data: p.advanced(by: descBase),
                                         length: descLen) {
                startedFlows.insert(srcref)
                emit(.flowStarted(desc))
            }
        }
        if startedFlows.contains(srcref) {
            emit(.flowUpdated(flowID: srcref, bytesIn: rxbytes, bytesOut: txbytes))
        }
    }

    private func handleSrcCounts(_ p: UnsafeRawPointer, length: Int) {
        guard length >= 144 else { return }   // hdr + srcref + event_flags + counts
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        guard startedFlows.contains(srcref) else { return }
        let rxbytes = p.load(fromByteOffset: 32 + 8, as: UInt64.self)
        let txbytes = p.load(fromByteOffset: 32 + 24, as: UInt64.self)
        emit(.flowUpdated(flowID: srcref, bytesIn: rxbytes, bytesOut: txbytes))
    }

    private func handleSrcDesc(_ p: UnsafeRawPointer, length: Int) {
        // SRC_DESC layout: hdr + srcref + event_flags + provider +
        // reserved[4] + data[].
        guard length > NSTAT_DESC_HEADER_SIZE else { return }
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        let provider = p.load(fromByteOffset: 32, as: UInt32.self)
        let descLen = length - NSTAT_DESC_HEADER_SIZE
        guard !startedFlows.contains(srcref) else { return }

        if let desc = makeDescriptor(srcref: srcref, provider: provider,
                                     data: p.advanced(by: NSTAT_DESC_HEADER_SIZE),
                                     length: descLen) {
            startedFlows.insert(srcref)
            emit(.flowStarted(desc))
        }
    }

    /// Build a FlowDescriptor from a provider-specific descriptor blob.
    /// Only TCP/UDP providers are supported; others are dropped.
    private func makeDescriptor(srcref: UInt64,
                                provider: UInt32,
                                data: UnsafeRawPointer,
                                length: Int) -> FlowDescriptor? {
        switch NStatProvider(rawValue: provider) {
        case .tcpUserland, .tcpKernel:
            guard length >= TCPDescriptorOffsets.pname + 64 else { return nil }
            let pid = Int32(bitPattern: data.load(
                fromByteOffset: TCPDescriptorOffsets.pid, as: UInt32.self))
            guard let remote = parseSockaddrUnion(data,
                                                  offset: TCPDescriptorOffsets.remote,
                                                  totalLength: length) else { return nil }
            let local = parseSockaddrUnion(data,
                                           offset: TCPDescriptorOffsets.local,
                                           totalLength: length)
                ?? SocketAddress(host: "", port: 0)
            let pname = resolveProcessName(pid: pid)
                ?? parseCString(data,
                                offset: TCPDescriptorOffsets.pname,
                                maxLen: 64,
                                totalLength: length)
            return FlowDescriptor(flowID: srcref, pid: pid, processName: pname,
                                  proto: IPPROTO_TCP, local: local, remote: remote)

        case .udpUserland, .udpKernel:
            guard length >= UDPDescriptorOffsets.pname + 64 else { return nil }
            let pid = Int32(bitPattern: data.load(
                fromByteOffset: UDPDescriptorOffsets.pid, as: UInt32.self))
            guard let remote = parseSockaddrUnion(data,
                                                  offset: UDPDescriptorOffsets.remote,
                                                  totalLength: length) else { return nil }
            let local = parseSockaddrUnion(data,
                                           offset: UDPDescriptorOffsets.local,
                                           totalLength: length)
                ?? SocketAddress(host: "", port: 0)
            let pname = resolveProcessName(pid: pid)
                ?? parseCString(data,
                                offset: UDPDescriptorOffsets.pname,
                                maxLen: 64,
                                totalLength: length)
            return FlowDescriptor(flowID: srcref, pid: pid, processName: pname,
                                  proto: IPPROTO_UDP, local: local, remote: remote)

        default:
            return nil
        }
    }

    private func emit(_ kind: NetworkFlowEvent.Kind) {
        let event = NetworkFlowEvent(kind: kind, timestamp: Date())
        eventHandler?(event)
    }
}
