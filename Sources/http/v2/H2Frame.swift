//
//  H2Frame.swift
//  Nutil
//
//  Created by Jamol Bao on 12/24/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

let kH2MaxStreamId: UInt32 = 0x7FFFFFFF
let kH2FrameHeaderSize = 9
let kH2PriorityPayloadSize = 5
let kH2RSTStreamPayloadSize = 4
let kH2SettingItemSize = 6
let kH2PingPayloadSize = 8
let kH2WindowUpdatePayloadSize = 4
let kH2WindowUpdateFrameSize = kH2FrameHeaderSize + kH2WindowUpdatePayloadSize

let kH2DefaultFrameSize = 16384
let kH2DefaultWindowSize = 65535
let kH2MaxWindowSize = 2147483647

let kH2FrameFlagEndStream: UInt8  = 0x01
let kH2FrameFlagAck: UInt8        = 0x01
let kH2FrameFlagEndHeaders: UInt8 = 0x04
let kH2FrameFlagPadded: UInt8     = 0x08
let kH2FrameFlagPriority: UInt8   = 0x20

enum H2FrameType : UInt8 {
    case data           = 0
    case headers        = 1
    case priority       = 2
    case rststream      = 3
    case settings       = 4
    case pushPromise    = 5
    case ping           = 6
    case goaway         = 7
    case windowUpdate   = 8
    case continuation   = 9
}

enum H2SettingsID : UInt16 {
    case headerTableSize        = 1
    case enablePush             = 2
    case maxConcurrentStreams   = 3
    case initialWindowSize      = 4
    case maxFrameSize           = 5
    case maxHeaderListSize      = 6
}

enum H2Error : Int32 {
    case noError            = 0
    case protocolError      = 1
    case internalError      = 2
    case flowControlError   = 3
    case settingsTimeout    = 4
    case streamClosed       = 5
    case frameSizeError     = 6
    case refusedStream      = 7
    case cancel             = 8
    case compressionError   = 9
    case connectError       = 10
    case enhanceYourCalm    = 11
    case inadequateSecurity = 12
    case http11Required     = 13
}

let kH2HeaderMethod = ":method"
let kH2HeaderScheme = ":scheme"
let kH2HeaderAuthority = ":authority"
let kH2HeaderPath = ":path"
let kH2HeaderStatus = ":status"

struct H2Priority {
    var streamId: UInt32 = 0
    var weight: UInt16 = 16
    var exclusive = false
}

struct FrameHeader {
    var length = 0
    var type: UInt8 = 0
    var flags: UInt8 = 0
    var streamId: UInt32 = 0
    
    var hasPadding: Bool {
        return (flags & kH2FrameFlagPadded) != 0
    }
    
    var hasPriority: Bool {
        return (flags & kH2FrameFlagPriority) != 0
    }
    
    var hasEndHeaders: Bool {
        return (flags & kH2FrameFlagEndHeaders) != 0
    }
    
    var hasEndStream: Bool {
        return (flags & kH2FrameFlagEndStream) != 0
    }
    
    var hasAck: Bool {
        return (flags & kH2FrameFlagAck) != 0
    }
    
    func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        if len < kH2FrameHeaderSize {
            return -1
        }
        encode_u24(dst, UInt32(length))
        dst[3] = type
        dst[4] = flags
        encode_u32(dst + 5, streamId)
        return kH2FrameHeaderSize
    }
    
    mutating func decode(_ src: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        if len < kH2FrameHeaderSize {
            return false
        }
        if (src[5] & 0x80) != 0 {
            // check reserved bit
        }
        length = Int(decode_u24(src))
        type = src[3]
        flags = src[4]
        streamId = decode_u32(src + 5)
        return true
    }
}

class H2Frame {
    var hdr = FrameHeader()
    var streamId: UInt32 {
        get {
            return hdr.streamId
        }
        set {
            hdr.streamId = newValue
        }
    }
    
    func addFlags(_ flags: UInt8) {
        hdr.flags |= flags
    }
    
    func clearFlags(_ flags: UInt8) {
        hdr.flags &= ~flags
    }
    
    func getFlags() -> UInt8 {
        return hdr.flags
    }
    
    func hasEndStream() -> Bool {
        return (getFlags() & kH2FrameFlagEndStream) != 0
    }
    
    func type() -> H2FrameType {
        fatalError("MUST override type")
    }
    
    func calcPayloadSize() -> Int {
        fatalError("MUST override calcPayloadSize")
    }
    
    func getPayloadLength() -> Int {
        if hdr.length > 0 {
            return hdr.length
        } else {
            return calcPayloadSize()
        }
    }
    
    func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        fatalError("MUST override encode")
    }
    
    func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        fatalError("MUST override decode")
    }
    
    func calcFrameSize() -> Int {
        return kH2FrameHeaderSize + calcPayloadSize()
    }
    
    func setFrameHeader(_ hdr: FrameHeader) {
        self.hdr = hdr
    }
    
    func encodeHeader(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int, _ hdr: FrameHeader) -> Int {
        return hdr.encode(dst, len)
    }
    
    func encodeHeader(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        hdr.type = type().rawValue
        hdr.length = calcPayloadSize()
        return hdr.encode(dst, len)
    }
    
    class func encodePriority(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int, _ pri: H2Priority) -> Int {
        var pri = pri
        if len < kH2PriorityPayloadSize {
            return -1
        }
        pri.streamId &= 0x7FFFFFFF
        if pri.exclusive {
            pri.streamId |= 0x80000000
        }
        encode_u32(dst, pri.streamId)
        dst[4] = UInt8(pri.weight & 0xFF)
        
        return kH2PriorityPayloadSize
    }
    
    class func decodePriority(_ src: UnsafePointer<UInt8>, _ len: Int) -> (err: H2Error, pri: H2Priority) {
        var pri = H2Priority()
        if len < kH2PriorityPayloadSize {
            return (.frameSizeError, pri)
        }
        pri.streamId = decode_u32(src)
        pri.exclusive = (pri.streamId >> 31) != 0
        pri.streamId &= 0x7FFFFFFF
        pri.weight = UInt16(src[4]) + 1
        return (.noError, pri)
    }
}

class DataFrame : H2Frame {
    var data: UnsafeRawPointer?
    var size = 0
    
    override func type() -> H2FrameType {
        return .data
    }
    
    override func calcPayloadSize() -> Int {
        return size
    }
    
    func setData(_ data: UnsafeRawPointer?, _ len: Int) {
        self.data = data
        self.size = len
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return -1
        }
        pos += ret
        if len - pos < size {
            return -1
        }
        if data != nil && size > 0 {
            memcpy(dst + pos, data, size)
            pos += size
        }
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        var ptr = payload
        var len = hdr.length
        var padLen = 0
        if hdr.hasPadding {
            padLen = Int(ptr[0])
            ptr += 1
            if padLen >= len {
                return .protocolError
            }
            len -= padLen + 1
        }
        data = UnsafeRawPointer(ptr)
        size = len
        return .noError
    }
}

class HeadersFrame : H2Frame {
    var pri = H2Priority()
    var block: UnsafeRawPointer?
    var bsize = 0
    
    var headers: NameValueArray = []
    var hsize = 0
    
    override func type() -> H2FrameType {
        return .headers
    }
    
    override func calcPayloadSize() -> Int {
        var sz = bsize
        if hdr.hasPriority {
            sz += kH2PriorityPayloadSize
        }
        return sz
    }
    
    func hasPriority() -> Bool {
        return (getFlags() & kH2FrameFlagPriority) != 0
    }
    
    func hasEndHeaders() -> Bool {
        return (getFlags() & kH2FrameFlagEndHeaders) != 0
    }
    
    func setHeaders(_ headers: NameValueArray, _ hdrSize: Int) {
        self.headers = headers
        hsize = hdrSize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        var ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if hdr.hasPriority {
            ret = H2Frame.encodePriority(dst + pos, len - pos, pri)
            if ret < 0 {
                return ret
            }
            pos += ret
        }
        if len - pos < bsize {
            return -1
        }
        memcpy(dst + pos, block, bsize)
        pos += bsize
        return pos
    }
    
    func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int, _ bsize: Int) -> Int {
        self.bsize = bsize
        var pos = 0
        var ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if hdr.hasPriority {
            ret = H2Frame.encodePriority(dst + pos, len - pos, pri)
            if ret < 0 {
                return ret
            }
            pos += ret
        }
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        var ptr = payload
        var len = hdr.length
        var padLen = 0
        if hdr.hasPadding {
            padLen = Int(ptr[0])
            ptr += 1
            if padLen >= len {
                return .protocolError
            }
            len -= padLen + 1
        }
        if hdr.hasPriority {
            let ret = H2Frame.decodePriority(ptr, len)
            if ret.err != .noError {
                return ret.err
            }
            ptr += kH2PriorityPayloadSize
            len -= kH2PriorityPayloadSize
        }
        block = UnsafeRawPointer(ptr)
        bsize = len
        return .noError
    }
}

class PriorityFrame : H2Frame {
    var pri = H2Priority()
    
    override func type() -> H2FrameType {
        return .priority
    }
    
    override func calcPayloadSize() -> Int {
        return kH2PriorityPayloadSize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        var ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        ret = H2Frame.encodePriority(dst + pos, len - pos, pri)
        if ret < 0 {
            return ret
        }
        pos += ret
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        let ret = H2Frame.decodePriority(payload, hdr.length)
        pri = ret.pri
        return ret.err
    }
}

class RSTStreamFrame : H2Frame {
    var errCode: UInt32 = 0
    
    override func type() -> H2FrameType {
        return .rststream
    }
    
    override func calcPayloadSize() -> Int {
        return kH2RSTStreamPayloadSize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        encode_u32(dst + pos, errCode)
        pos += 4
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        if hdr.length != 4 {
            return .frameSizeError
        }
        errCode = decode_u32(payload)
        return .noError
    }
}

typealias H2SettingArray = [(key: UInt16, value: UInt32)]

class SettingsFrame : H2Frame {
    var params: H2SettingArray = []
    
    var ack: Bool {
        get {
            return hdr.hasAck
        }
        
        set {
            if newValue {
                addFlags(kH2FrameFlagAck)
            } else {
                clearFlags(kH2FrameFlagAck)
            }
        }
    }
    
    override func type() -> H2FrameType {
        return .settings
    }
    
    override func calcPayloadSize() -> Int {
        return kH2SettingItemSize * params.count
    }
    
    func encodePayload(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int, _ para: H2SettingArray) -> Int {
        var pos = 0
        for kv in para {
            if pos + kH2SettingItemSize > len {
                return -1
            }
            encode_u16(dst + pos, kv.key)
            pos += 2
            encode_u32(dst + pos, kv.value)
            pos += 4
        }
        return pos
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        var ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        ret = encodePayload(dst + pos, len - pos, params)
        if ret < 0 {
            return ret
        }
        pos += ret
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId != 0 {
            return .protocolError
        }
        if ack && hdr.length != 0 {
            return .frameSizeError
        }
        if hdr.length % kH2SettingItemSize != 0 {
            return .frameSizeError
        }
        var ptr = payload
        var len = hdr.length
        params.removeAll()
        while len > 0 {
            let key = decode_u16(ptr)
            let value = decode_u32(ptr + 2)
            params.append((key, value))
            ptr += kH2SettingItemSize
            len -= kH2SettingItemSize
        }
        return .noError
    }
}

class PushPromiseFrame : H2Frame {
    var promisedStreamId: UInt32 = 0
    var block: UnsafeRawPointer?
    var bsize = 0
    
    override func type() -> H2FrameType {
        return .pushPromise
    }
    
    override func calcPayloadSize() -> Int {
        return 4 + bsize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if len - pos < calcPayloadSize() {
            return -1
        }
        encode_u32(dst + pos, promisedStreamId)
        pos += 4
        if block != nil && bsize > 0 {
            memcpy(dst + pos, block, bsize)
            pos += bsize
        }
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        var ptr = payload
        var len = hdr.length
        var padLen = 0
        if hdr.hasPadding {
            padLen = Int(ptr[0])
            ptr += 1
            if padLen >= len {
                return .protocolError
            }
            len -= padLen + 1
        }
        if len < 4 {
            return .frameSizeError
        }
        promisedStreamId = decode_u32(ptr) & 0x7FFFFFFF
        ptr += 4
        len -= 4
        if len > 0 {
            block = UnsafeRawPointer(ptr)
            bsize = len
        }
        return .noError
    }
}

class PingFrame : H2Frame {
    var data = Array<UInt8>(repeating: 0, count: kH2PingPayloadSize)
    var ack: Bool {
        get {
            return hdr.hasAck
        }
        
        set {
            if newValue {
                addFlags(kH2FrameFlagAck)
            } else {
                clearFlags(kH2FrameFlagAck)
            }
        }
    }
    
    override func type() -> H2FrameType {
        return .ping
    }
    
    override func calcPayloadSize() -> Int {
        return kH2PingPayloadSize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if len - pos < calcPayloadSize() {
            return -1
        }
        memcpy(dst + pos, data, kH2PingPayloadSize)
        pos += kH2PingPayloadSize
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId != 0 {
            return .protocolError
        }
        if hdr.length != kH2PingPayloadSize {
            return .frameSizeError
        }
        let bbuf = UnsafeBufferPointer<UInt8>(start: payload, count: hdr.length)
        data = Array(bbuf)
        return .noError
    }
}

class GoawayFrame : H2Frame {
    var lastStreamId: UInt32 = 0
    var errCode: UInt32 = 0
    var data: UnsafeRawPointer?
    var size = 0
    
    override func type() -> H2FrameType {
        return .goaway
    }
    
    override func calcPayloadSize() -> Int {
        return 8 + size
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if len - pos < calcPayloadSize() {
            return -1
        }
        encode_u32(dst + pos, lastStreamId)
        pos += 4
        encode_u32(dst + pos, errCode)
        pos += 4
        if size > 0 {
            memcpy(dst + pos, data, size)
            pos += size
        }
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId != 0 {
            return .protocolError
        }
        if hdr.length < 8 {
            return .frameSizeError
        }
        var ptr = payload
        var len = hdr.length
        lastStreamId = decode_u32(ptr) & 0x7FFFFFFF
        ptr += 4
        len -= 4
        errCode = decode_u32(ptr)
        ptr += 4
        len -= 4
        if len > 0 {
            data = UnsafeRawPointer(ptr)
            size = len
        }
        return .noError
    }
}

class WindowUpdateFrame : H2Frame {
    var windowSizeIncrement: UInt32 = 0
    
    override func type() -> H2FrameType {
        return .windowUpdate
    }
    
    override func calcPayloadSize() -> Int {
        return kH2WindowUpdatePayloadSize
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if len - pos < calcPayloadSize() {
            return -1
        }
        encode_u32(dst + pos, windowSizeIncrement)
        pos += 4
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.length != kH2WindowUpdatePayloadSize {
            return .frameSizeError
        }
        windowSizeIncrement = decode_u32(payload) & 0x7FFFFFFF
        return .noError
    }
}

class ContinuationFrame : H2Frame {
    var block: UnsafeRawPointer?
    var bsize = 0
    
    var headers: NameValueArray = []
    var hsize = 0
    
    override func type() -> H2FrameType {
        return .continuation
    }
    
    override func calcPayloadSize() -> Int {
        return bsize
    }
    
    func hasEndHeaders() -> Bool {
        return (getFlags() & kH2FrameFlagEndHeaders) != 0
    }
    
    override func encode(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var pos = 0
        let ret = encodeHeader(dst, len)
        if ret < 0 {
            return ret
        }
        pos += ret
        if len - pos < calcPayloadSize() {
            return -1
        }
        if block != nil && bsize > 0 {
            memcpy(dst + pos, block, bsize)
            pos += bsize
        }
        return pos
    }
    
    override func decode(_ hdr: FrameHeader, _ payload: UnsafePointer<UInt8>) -> H2Error {
        setFrameHeader(hdr)
        if hdr.streamId == 0 {
            return .protocolError
        }
        if hdr.length > 0 {
            block = UnsafeRawPointer(payload)
            bsize = hdr.length
        }
        return .noError
    }
}
