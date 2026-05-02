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
// 24 bytes — used for both QUERY_SRC and GET_UPDATE shapes that take a srcref.

struct nstat_msg_src_added_wire {
    var hdr: nstat_msg_hdr = nstat_msg_hdr()
    var srcref: UInt64 = 0
    var provider: UInt32 = 0
    var reserved: UInt32 = 0   // u_int8_t reserved[4]
}
// 32 bytes

struct nstat_msg_src_removed_wire {
    var hdr: nstat_msg_hdr = nstat_msg_hdr()
    var srcref: UInt64 = 0
}
// 24 bytes

struct nstat_counts {
    var rxpackets: UInt64
    var rxbytes: UInt64
    var txpackets: UInt64
    var txbytes: UInt64
    var cell_rxbytes: UInt64
    var cell_txbytes: UInt64
    var wifi_rxbytes: UInt64
    var wifi_txbytes: UInt64
    var wired_rxbytes: UInt64
    var wired_txbytes: UInt64
    var rxduplicatebytes: UInt32
    var rxoutoforderbytes: UInt32
    var txretransmit: UInt32
    var connectattempts: UInt32
    var connectsuccesses: UInt32
    var min_rtt: UInt32
    var avg_rtt: UInt32
    var var_rtt: UInt32
}
// 112 bytes

struct nstat_msg_src_counts_wire {
    var hdr: nstat_msg_hdr
    var srcref: UInt64
    var event_flags: UInt64
    var counts: nstat_counts
}
// 16 + 8 + 8 + 112 = 144 bytes

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
        // sin_port at offset 2 (network byte order); sin_addr at offset 4
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var addrBytes = [bytes[4], bytes[5], bytes[6], bytes[7]]
        let host = withUnsafePointer(to: &addrBytes) { ptr -> String in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, ptr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        return SocketAddress(host: host, port: port)
    case AF_INET6:
        guard offset + 28 <= totalLength else { return nil }
        // sin6_port at offset 2; sin6_addr at offset 8 (16 bytes)
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var addrBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { addrBytes[i] = bytes[8 + i] }
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
