//
//  NTStatProtocol.swift
//  AgentRunner
//
//  Constants and binary layouts for the macOS private SPI `ntstat`
//  (Network Statistics) — the kernel control interface that backs
//  /usr/bin/nettop. Values are vendored from xnu-11215.61.5
//  (bsd/net/ntstat.h). See:
//    https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.61.5/bsd/net/ntstat.h
//
//  This is private API. macOS minor updates may change message formats
//  or struct field offsets. The project explicitly accepts that risk:
//  on incompatibility the source throws on `start()` and the app
//  transitions to an "unavailable" state (see NetworkFlowSource.swift).
//
//  Layout strategy: Swift structs declared with fixed-width primitives
//  match the natural C alignment on Apple platforms, so MemoryLayout
//  size/stride align with the kernel's expected encoding. Where we read
//  fields out of variable-payload messages (SRC_UPDATE descriptors), we
//  use byte offsets computed from the xnu source rather than mapping a
//  whole struct — this minimizes drift if Apple appends new fields.
//

import Darwin
import Foundation

// MARK: - Kernel control name

/// Control name registered by the ntstat kernel module.
let NSTAT_CONTROL_NAME = "com.apple.network.statistics"

// MARK: - Message type IDs

enum NStatMsgType: UInt32 {
    // Generic responses
    case success           = 0
    case error             = 1

    // Requests (1000+)
    case addSrc            = 1001
    case addAllSrcs        = 1002
    case remSrc            = 1003
    case querySrc          = 1004
    case getSrcDesc        = 1005
    case setFilter         = 1006   // obsolete
    case getUpdate         = 1007
    case subscribeSysinfo  = 1008

    // Responses / notifications (10000+)
    case srcAdded          = 10001
    case srcRemoved        = 10002
    case srcDesc           = 10003
    case srcCounts         = 10004
    case sysinfoCounts     = 10005
    case srcUpdate         = 10006
    case srcExtendedUpdate = 10007
}

// MARK: - Provider IDs

enum NStatProvider: UInt32 {
    case none         = 0
    case route        = 1
    case tcpKernel    = 2
    case tcpUserland  = 3
    case udpKernel    = 4
    case udpUserland  = 5
    case ifnet        = 6
    case sysinfo      = 7
    case quicUserland = 8
    case connUserland = 9
    case udpSubflow   = 10
}

// MARK: - Filter flags
// Only the subset we actually use, to keep this file small.

struct NStatFilter {
    static let acceptUnknown:   UInt64 = 0x0000_0000_0000_0001
    static let acceptLoopback:  UInt64 = 0x0000_0000_0000_0002
    static let acceptCellular:  UInt64 = 0x0000_0000_0000_0004
    static let acceptWiFi:      UInt64 = 0x0000_0000_0000_0008
    static let acceptWired:     UInt64 = 0x0000_0000_0000_0010
    static let acceptAWDL:      UInt64 = 0x0000_0000_0000_0020
    static let acceptExpensive: UInt64 = 0x0000_0000_0000_0040

    static let useUpdateForAdd:        UInt64 = 0x0000_0000_0020_0000
    static let providerNoZeroBytes:    UInt64 = 0x0000_0000_0040_0000
    static let providerNoZeroDeltas:   UInt64 = 0x0000_0000_0080_0000

    /// Production filter: external interfaces only, push initial UPDATE
    /// instead of a separate ADDED, suppress zero-byte chatter.
    static let externalProduction: UInt64 =
        acceptCellular | acceptWiFi | acceptWired |
        useUpdateForAdd | providerNoZeroDeltas
}

// MARK: - Special source ref values

/// Sentinel meaning "all sources" in QUERY_SRC / GET_UPDATE.
let NSTAT_SRC_REF_ALL: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
let NSTAT_SRC_REF_INVALID: UInt64 = 0

// MARK: - Wire structs (header + small messages)
//
// Field order/sizes match xnu ntstat.h. `__attribute__((aligned(8)))`
// in the C header is satisfied by Swift's natural alignment for u64
// fields when they follow a 16-byte header.

struct nstat_msg_hdr {
    var context: UInt64 = 0
    var type: UInt32 = 0
    var length: UInt16 = 0
    var flags: UInt16 = 0
}
// MemoryLayout<nstat_msg_hdr>.size == 16

struct nstat_msg_add_all_srcs {
    var hdr: nstat_msg_hdr = nstat_msg_hdr()
    var filter: UInt64 = 0
    var events: UInt64 = 0
    var provider: UInt32 = 0
    var target_pid: Int32 = 0
    /// uuid_t target_uuid — 16 bytes, zero for "no specific target".
    var target_uuid: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
// MemoryLayout<nstat_msg_add_all_srcs>.size == 56

struct nstat_msg_query_src {
    var hdr: nstat_msg_hdr = nstat_msg_hdr()
    var srcref: UInt64 = 0
}
// 24 bytes — used for QUERY_SRC, GET_UPDATE, GET_SRC_DESC requests.

// Inbound (kernel→userland) message layouts are not modeled as Swift
// structs. NTStatFlowSource reads only the specific fields it needs
// out of the receive buffer using `load(fromByteOffset:as:)`. This is
// alignment-safe regardless of where the message lands in the buffer
// and stays robust across xnu versions that may append fields.
//
// Reference layouts (hdr always at offset 0):
//   SRC_ADDED:    hdr | srcref(u64@16) | provider(u32@24) | reserved[4]
//   SRC_REMOVED:  hdr | srcref(u64@16)
//   SRC_COUNTS:   hdr | srcref(u64@16) | event_flags(u64@24) | counts(@32)
//   SRC_UPDATE:   hdr | srcref(u64@16) | event_flags(u64@24) | counts(@32) |
//                 provider(u32@144)    | reserved[4]@148    | data[]@152
//
// nstat_counts (112 bytes, starts at offset 32 in COUNTS/UPDATE):
//   rxpackets(u64@0) rxbytes(u64@8) txpackets(u64@16) txbytes(u64@24)
//   ... + 6 per-interface u64 + 8 misc u32 fields
// We touch only rxbytes and txbytes — see NTStatFlowSource.

// nstat_msg_src_update is variable-length:
//   hdr (16) + srcref (8) + event_flags (8) + counts (112) + provider (4) +
//   reserved[4] + data[]
// data[] is the provider-specific descriptor (nstat_tcp_descriptor for
// TCP_USERLAND, nstat_udp_descriptor for UDP_USERLAND).
//
// For SRC_DESC the fixed prefix is the same (header fields) but counts
// is replaced by descriptor. We don't decode the whole descriptor — we
// only read the fields we need at known byte offsets within data[].

let NSTAT_UPDATE_HEADER_SIZE = 152   // hdr + srcref + event_flags + counts + provider + reserved
let NSTAT_DESC_HEADER_SIZE   = 40    // hdr + srcref + event_flags + provider + reserved
                                     // (NSTAT_SRC_DESCRIPTION_FIELDS macro expansion size)

// MARK: - Descriptor field offsets (within the descriptor, i.e. data[])
//
// These offsets are computed from xnu-11215.61.5 layouts. activity_bitmap_t
// is 24 bytes (start: u64, bitmap[2]: u64). On older macOS where the
// descriptor is shorter, the fields BEFORE the offsets we read are
// believed unchanged (timestamps + activity_bitmap + initial u32 fields).
// Fields we touch are conservatively in the stable prefix.

enum TCPDescriptorOffsets {
    /// u_int32_t pid — at offset 116 within descriptor.
    static let pid     = 116
    /// union sockaddr_in/in6 remote — at offset 152 within descriptor.
    /// sockaddr_in6 is 28 bytes; sockaddr_in is 16 bytes.
    static let remote  = 152
    /// union sockaddr local — at offset 124.
    static let local   = 124
    /// char pname[64] — at offset 196.
    static let pname   = 196
}

enum UDPDescriptorOffsets {
    static let local   = 56
    static let remote  = 84
    static let pid     = 128
    static let pname   = 132
}

// MARK: - sockaddr family parse helpers

/// Decode the host:port pair out of a 28-byte sockaddr union slot at
/// `data + offset`. Returns nil for AF_UNSPEC / unrecognized families.
func parseSockaddrUnion(_ data: UnsafeRawPointer, offset: Int, totalLength: Int) -> SocketAddress? {
    guard offset + 2 <= totalLength else { return nil }
    let bytes = data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    let family = Int32(bytes[1])   // sa_family
    switch family {
    case AF_INET:
        guard offset + 8 <= totalLength else { return nil }
        // sin_port at offset 2 (network byte order); sin_addr at offset 4.
        // Build the dotted-quad directly. Earlier this called inet_ntop
        // via `withUnsafePointer(to: &addrBytes)` where addrBytes was a
        // Swift Array — that hands inet_ntop a pointer to the Array
        // STRUCT (buffer pointer + count metadata), not the 4 IP bytes.
        // Result was nondeterministic garbage IPs that never matched
        // ProviderRegistry. The IPv6 path below uses the correct
        // `withUnsafeBufferPointer { buf in ... buf.baseAddress }` form.
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let host = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
        return SocketAddress(host: host, port: port)
    case AF_INET6:
        guard offset + 28 <= totalLength else { return nil }
        // sin6_port at offset 2; sin6_addr at offset 8 (16 bytes)
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var addrBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { addrBytes[i] = bytes[8 + i] }
        // IPv4-mapped IPv6 normalization (`::ffff:1.2.3.4` → `1.2.3.4`).
        // Empirically, the macOS kernel stores the actual transport
        // family in ntstat descriptors — IPv4 transports show up as
        // AF_INET, not AF_INET6 with a mapped address. Mapped form is
        // a userspace socket-API abstraction. So this code path is
        // currently dead. Kept commented as a marker in case a future
        // xnu starts surfacing the mapped form to ntstat clients;
        // uncomment if we ever observe `::ffff:` prefixes in unmatched
        // flow logs.
        //
        // let isV4Mapped = addrBytes.prefix(10).allSatisfy { $0 == 0 } &&
        //                  addrBytes[10] == 0xFF && addrBytes[11] == 0xFF
        // if isV4Mapped {
        //     let host = "\(addrBytes[12]).\(addrBytes[13]).\(addrBytes[14]).\(addrBytes[15])"
        //     return SocketAddress(host: host, port: port)
        // }
        let host = addrBytes.withUnsafeBufferPointer { buf -> String in
            var s = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, buf.baseAddress, &s, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: s)
        }
        return SocketAddress(host: host, port: port)
    default:
        return nil
    }
}

/// Decode a fixed-size C string field (pname[64]) at the given offset.
func parseCString(_ data: UnsafeRawPointer, offset: Int, maxLen: Int, totalLength: Int) -> String {
    let actualLen = min(maxLen, max(0, totalLength - offset))
    guard actualLen > 0 else { return "" }
    let bytes = data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    var end = 0
    while end < actualLen, bytes[end] != 0 { end += 1 }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: end), as: UTF8.self)
}
