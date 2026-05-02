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
//  start() opens a socket to com.apple.network.statistics, sends two
//  ADD_ALL_SRCS subscriptions (TCP_USERLAND + UDP_USERLAND), and arms a
//  DispatchSourceRead. A background read source drains messages and a
//  periodic timer emits GET_UPDATE to refresh byte counters.
//
//  stop() is idempotent. After stop() the source can be re-started
//  (sleep/wake support) — internal state is reset on every start().
//

import Darwin
import Foundation

/// Sized to hold a few ntstat messages worth of bytes. Kernel
/// SRC_UPDATE for TCP_USERLAND can run ~500 bytes.
private let NTSTAT_READ_BUFFER_SIZE = 64 * 1024

/// CTLIOCGINFO is `_IOWR('N', 3, struct ctl_info)`. Swift can't import
/// macros that compute on a sizeof, so we hand-evaluate it. The encoding
/// is stable (sys/ioccom.h has not changed in years):
///   IOC_INOUT (0xC0000000) | ((sizeof(ctl_info) & 0x1FFF) << 16)
///       | ('N' << 8) | 3
/// sizeof(ctl_info) on macOS = 4 (u_int32_t ctl_id) + 96 (char[96]) = 100.
private let CTLIOCGINFO: UInt = 0xC064_4E03

/// How often we poll the kernel for fresh counters. Matches the
/// SessionManager publish tick so per-flow rates align with the
/// existing 2s-window state-machine semantics.
private let NTSTAT_UPDATE_POLL_INTERVAL: TimeInterval = 2.0

final class NTStatFlowSource: NetworkFlowSource {

    enum FlowFilter {
        case all
        case external
    }

    private let filter: FlowFilter
    private let queue = DispatchQueue(label: "ai.ww-w.AgentRunner.ntstat")

    // Live state — all touched only on `queue`.
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var updateTimer: DispatchSourceTimer?
    private var eventHandler: (@Sendable (NetworkFlowEvent) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var contextCounter: UInt64 = 1
    private var isShuttingDown = false

    /// Tracks which srcref values we've already reported as `flowStarted`
    /// so a periodic UPDATE doesn't re-emit the start event. Map value
    /// holds the last-known process name (for late-arriving counts after
    /// a flow ends, which we ignore).
    private var startedFlows: Set<UInt64> = []

    init(filter: FlowFilter = .external) {
        self.filter = filter
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    // MARK: - NetworkFlowSource

    func start(
        eventHandler: @escaping @Sendable (NetworkFlowEvent) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) throws {
        // Synchronous setup so we can throw before returning. Run the
        // socket open + subscription dance on the I/O queue to keep all
        // mutable state single-threaded thereafter.
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

        // 4. Subscribe TCP_USERLAND + UDP_USERLAND.
        try subscribeLocked(provider: .tcpUserland)
        try subscribeLocked(provider: .udpUserland)

        // 5. Arm read source on the I/O queue.
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainSocket() }
        rs.setCancelHandler { [weak self] in self?.handleSourceCancelled() }
        readSource = rs
        rs.resume()

        // 6. Periodic GET_UPDATE poll.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + NTSTAT_UPDATE_POLL_INTERVAL,
                   repeating: NTSTAT_UPDATE_POLL_INTERVAL,
                   leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.requestUpdate() }
        updateTimer = t
        t.resume()

        NSLog("AgentRunner: ntstat flow source started fd=\(fd) filter=\(filter)")
    }

    private func tearDownLocked() {
        isShuttingDown = true
        updateTimer?.cancel(); updateTimer = nil
        readSource?.cancel(); readSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
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

    // MARK: - Subscription request

    private func filterMask() -> UInt64 {
        switch filter {
        case .all:
            return NStatFilter.acceptCellular | NStatFilter.acceptWiFi |
                   NStatFilter.acceptWired | NStatFilter.acceptLoopback |
                   NStatFilter.useUpdateForAdd | NStatFilter.providerNoZeroDeltas
        case .external:
            return NStatFilter.externalProduction
        }
    }

    private func subscribeLocked(provider: NStatProvider) throws {
        var msg = nstat_msg_add_all_srcs()
        msg.hdr.context = nextContext()
        msg.hdr.type = NStatMsgType.addAllSrcs.rawValue
        msg.hdr.length = UInt16(MemoryLayout<nstat_msg_add_all_srcs>.size)
        msg.hdr.flags = 0
        msg.filter = filterMask()
        msg.events = 0
        msg.provider = provider.rawValue
        msg.target_pid = 0
        msg.target_uuid = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

        let written = withUnsafeBytes(of: &msg) { buf -> Int in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        if written <= 0 {
            throw NetworkFlowSourceError.subscriptionFailed(errno: errno)
        }
    }

    private func requestUpdate() {
        guard fd >= 0 else { return }
        // GET_UPDATE with srcref = NSTAT_SRC_REF_ALL — refresh counts
        // for every tracked source. Kernel responds with SRC_UPDATE
        // messages (or SRC_COUNTS, depending on filter).
        var msg = nstat_msg_query_src()
        msg.hdr.context = nextContext()
        msg.hdr.type = NStatMsgType.getUpdate.rawValue
        msg.hdr.length = UInt16(MemoryLayout<nstat_msg_query_src>.size)
        msg.hdr.flags = 0
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
        guard fd >= 0 else { return }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: NTSTAT_READ_BUFFER_SIZE, alignment: 8)
        defer { buffer.deallocate() }

        // Drain everything that's currently readable.
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
            // Read the 16-byte header without alignment assumptions.
            let hdrPtr = chunk.advanced(by: offset).assumingMemoryBound(to: nstat_msg_hdr.self)
            let msgLen = Int(hdrPtr.pointee.length)
            let msgType = hdrPtr.pointee.type
            guard msgLen >= 16, offset + msgLen <= length else {
                NSLog("AgentRunner: ntstat truncated message len=\(msgLen) avail=\(length - offset)")
                return
            }
            let msgStart = chunk.advanced(by: offset)
            decodeMessage(msgStart, length: msgLen, type: msgType)
            offset += msgLen
        }
    }

    private func decodeMessage(_ p: UnsafeRawPointer, length: Int, type: UInt32) {
        guard let kind = NStatMsgType(rawValue: type) else { return }
        switch kind {
        case .srcAdded:
            handleSrcAdded(p, length: length)
        case .srcRemoved:
            handleSrcRemoved(p, length: length)
        case .srcUpdate, .srcExtendedUpdate:
            handleSrcUpdate(p, length: length)
        case .srcCounts:
            handleSrcCounts(p, length: length)
        case .srcDesc:
            handleSrcDesc(p, length: length)
        case .error:
            // Most "error" responses are normal (e.g., GET_UPDATE for
            // a srcref that just removed). Logging would be noisy.
            break
        case .success:
            break
        default:
            break
        }
    }

    private func handleSrcAdded(_ p: UnsafeRawPointer, length: Int) {
        // With useUpdateForAdd in the filter mask the kernel sends
        // SRC_UPDATE instead — but tolerate both shapes.
        guard length >= MemoryLayout<nstat_msg_src_added_wire>.size else { return }
        let added = p.assumingMemoryBound(to: nstat_msg_src_added_wire.self).pointee
        // Without a descriptor we can't classify the flow yet. Request one.
        var req = nstat_msg_query_src()
        req.hdr.context = nextContext()
        req.hdr.type = NStatMsgType.getSrcDesc.rawValue
        req.hdr.length = UInt16(MemoryLayout<nstat_msg_query_src>.size)
        req.hdr.flags = 0
        req.srcref = added.srcref
        _ = withUnsafeBytes(of: &req) { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    private func handleSrcRemoved(_ p: UnsafeRawPointer, length: Int) {
        guard length >= MemoryLayout<nstat_msg_src_removed_wire>.size else { return }
        let removed = p.assumingMemoryBound(to: nstat_msg_src_removed_wire.self).pointee
        if startedFlows.remove(removed.srcref) != nil {
            emit(.flowEnded(flowID: removed.srcref))
        }
    }

    private func handleSrcUpdate(_ p: UnsafeRawPointer, length: Int) {
        // Layout: hdr + srcref + event_flags + counts + provider +
        // reserved[4] + data[].
        guard length >= NSTAT_UPDATE_HEADER_SIZE else { return }
        let srcref = p.load(fromByteOffset: 16, as: UInt64.self)
        let counts = readCounts(p, offset: 32)
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
            emit(.flowUpdated(flowID: srcref,
                              bytesIn: counts.rxbytes,
                              bytesOut: counts.txbytes))
        }
    }

    private func handleSrcCounts(_ p: UnsafeRawPointer, length: Int) {
        guard length >= MemoryLayout<nstat_msg_src_counts_wire>.size else { return }
        let m = p.assumingMemoryBound(to: nstat_msg_src_counts_wire.self).pointee
        guard startedFlows.contains(m.srcref) else { return }
        emit(.flowUpdated(flowID: m.srcref,
                          bytesIn: m.counts.rxbytes,
                          bytesOut: m.counts.txbytes))
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

    // MARK: - Decoding helpers

    private func readCounts(_ p: UnsafeRawPointer, offset: Int) -> nstat_counts {
        return p.load(fromByteOffset: offset, as: nstat_counts.self)
    }

    /// Build a FlowDescriptor from a provider-specific descriptor blob.
    /// Only TCP/UDP USERLAND providers are supported — others are dropped.
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
            let pname = parseCString(data,
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
            let pname = parseCString(data,
                                     offset: UDPDescriptorOffsets.pname,
                                     maxLen: 64,
                                     totalLength: length)
            return FlowDescriptor(flowID: srcref, pid: pid, processName: pname,
                                  proto: IPPROTO_UDP, local: local, remote: remote)

        default:
            return nil
        }
    }

    // MARK: - Emit

    private func emit(_ kind: NetworkFlowEvent.Kind) {
        let event = NetworkFlowEvent(kind: kind, timestamp: Date())
        eventHandler?(event)
    }
}
