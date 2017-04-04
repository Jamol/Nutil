//
//  WSHandler.swift
//  Nutil
//
//  Created by Jamol Bao on 12/21/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

let kWSMaxPayloadSize = 10*1024*1024
let kWSMaskKeySize = 4
let kWSMaxHeaderSize = 14

enum WSError {
    case noErr
    case incomplete
    case handshake
    case invalidParam
    case invalidState
    case invalidFrame
    case invalidLength
    case protocolError
    case closed
}

enum WSOpcode: Equatable {
    case _continue_
    case text
    case binary
    case close
    case ping
    case pong
    case invalid(code: UInt8)
    
    init(code: UInt8) {
        switch code {
        case 0:  self = ._continue_
        case 1:  self = .text
        case 2:  self = .binary
        case 8:  self = .close
        case 9:  self = .ping
        case 10: self = .pong
        default: self = .invalid(code: code)
        }
    }
    
    var code: UInt8 {
        switch self {
        case ._continue_: return 0
        case .text: return 1
        case .binary: return 2
        case .close: return 8
        case .ping: return 9
        case .pong: return 10
        case .invalid(let code): return code
        }
    }
    
    var isControl: Bool {
        return self == .close || self == .ping || self == .pong
    }
}

enum WSMode {
    case client, server
}

typealias WSFrameCallback = (WSOpcode, Bool, UnsafeMutableRawPointer?, Int) -> Void

class WSHandler : HttpParserDelegate {
    
    enum DecodeState {
        case hdr1
        case hdr2
        case hdrex
        case maskey
        case data
        case closed
        case error
    }
    
    struct FrameHeader {
        var fin = false
        var opcode = WSOpcode.invalid(code: 0xFF)
        var mask = false
        var plen: UInt8 = 0
        var xpl: UInt64 = 0
        var maskey: [UInt8] = [0, 0, 0, 0]
        var length = 0
        
        mutating func reset() {
            fin = false
            opcode = .invalid(code: 0xFF)
            mask = false
            plen = 0
            xpl = 0
            length = 0
        }
    }
    
    struct DecodeContext {
        var hdr = FrameHeader()
        var state = DecodeState.hdr1
        var buf: [UInt8] = []
        var pos = 0
        
        mutating func reset() {
            hdr.reset()
            state = .hdr1
            buf = []
            pos = 0
        }
    }
    
    enum State {
        case handshake, open, error
    }
    
    fileprivate var state = State.handshake
    fileprivate var dctx = DecodeContext()
    
    fileprivate var parser = HttpParser()
    
    fileprivate var cbFrame: WSFrameCallback?
    fileprivate var cbHandshake: ErrorCallback?
    
    var mode = WSMode.client
    
    init() {
        parser.delegate = self
    }
    
    func buildUpgradeRequest(_ url: String, _ host: String, _ proto: String, _ origin: String) -> String {
        var str = "GET \(url) HTTP/1.1\r\n"
        str += "Host: \(host)\r\n"
        str += "Upgrade: websocket\r\n"
        str += "Connection: Upgrade\r\n"
        str += "Origin: \(origin)\r\n"
        str += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        str += "Sec-WebSocket-Protocol: \(proto)\r\n"
        str += "Sec-WebSocket-Version: 13\r\n"
        str += "\r\n"
        return str
    }
    
    func buildUpgradeResponse() -> String {
        let secWsKey = parser.headers["Sec-WebSocket-Key"]
        let protos = parser.headers["Sec-WebSocket-Protocol"]
        
        var str = "HTTP/1.1 101 Switching Protocols\r\n"
        str += "Upgrade: websocket\r\n"
        str += "Connection: Upgrade\r\n"
        str += "Sec-WebSocket-Accept: \(generateSecAcceptValue(secWsKey!))\r\n"
        if let protos = protos, !protos.isEmpty {
            str += "Sec-WebSocket-Protocol: \(protos)\r\n"
        }
        str += "\r\n"
        return str
    }
    
    func setHttpParser(_ parser: HttpParser) {
        self.parser = parser
        self.parser.delegate = self
        if parser.paused() {
            parser.resume()
        }
    }
    
    func handleRequest() {
        if !parser.isUpgradeTo(proto: kWebScoket) {
            errTrace("WSHandler, not WebSocket request")
            state = .error
            cbHandshake?(.invalidProto)
            return
        }
        let secWsKey = parser.headers["Sec-WebSocket-Key"]
        if secWsKey == nil {
            errTrace("WSHandler, no Sec-WebSocket-Key")
            state = .error
            cbHandshake?(.invalidProto)
            return
        }
        state = .open
        cbHandshake?(.noError)
    }
    
    func handleResponse() {
        if parser.isUpgradeTo(proto: kWebScoket) {
            state = .open
            cbHandshake?(.noError)
        } else {
            errTrace("WSHandler, invalid status code: \(parser.statusCode)")
            state = .error
            cbHandshake?(.invalidProto)
        }
    }
    
    func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> WSError {
        if state == .open {
            return decodeFrame(data, len)
        }
        if state == State.handshake {
            let bytesUsed = parser.parse(data: data, len: len)
            if state == .error {
                return WSError.handshake
            }
            if bytesUsed < len && state == .open {
                return decodeFrame(data + bytesUsed, len - bytesUsed)
            }
        } else {
            return .invalidState
        }
        return .noErr
    }
    
    func encodeFrameHeader(_ opcode: WSOpcode, _ fin: Bool, _ mkey: [UInt8]?, _ plen: Int, _ hdrBuffer: UnsafeMutablePointer<UInt8>) -> Int {
        var firstByte: UInt8 = opcode.code
        if fin {
            firstByte |= 0x80
        }
        var secondByte: UInt8 = 0
        if mkey != nil {
            secondByte = 0x80
        }
        var hdrSize = 2
        if plen <= 125 {
            secondByte |= UInt8(plen)
        } else if plen <= 0xFFFF {
            hdrSize += 2
            secondByte |= 126
        } else {
            hdrSize += 8
            secondByte |= 127
        }
        hdrBuffer[0] = firstByte
        hdrBuffer[1] = secondByte
        if (secondByte & 0x7F) == 126 {
            hdrBuffer[2] = UInt8((plen >> 8) & 0xFF)
            hdrBuffer[3] = UInt8(plen & 0xFF)
        } else if (secondByte & 0x7F) == 127 {
            hdrBuffer[2] = 0
            hdrBuffer[3] = 0
            hdrBuffer[4] = 0
            hdrBuffer[5] = 0
            hdrBuffer[6] = UInt8((plen >> 24) & 0xFF)
            hdrBuffer[7] = UInt8((plen >> 16) & 0xFF)
            hdrBuffer[8] = UInt8((plen >> 8) & 0xFF)
            hdrBuffer[9] = UInt8(plen & 0xFF)
        }
        if let mkey = mkey {
            memcpy(hdrBuffer + Int(hdrSize), mkey, kWSMaskKeySize)
            hdrSize += kWSMaskKeySize
        }
        return hdrSize
    }
    
    func decodeFrame(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> WSError {
        var pos = 0
        var b: UInt8 = 0
        while pos < len {
            switch dctx.state {
            case .hdr1:
                b = data[pos]
                pos += 1
                dctx.hdr.fin = (b >> 7) != 0
                dctx.hdr.opcode = WSOpcode(code: (b & 0x0F))
                if (b & 0x70) != 0 {
                    dctx.state = .error
                    return .invalidFrame
                }
                if !dctx.hdr.fin && dctx.hdr.opcode.isControl {
                    // Control frames MUST NOT be fragmented
                    dctx.state = .error
                    return .protocolError
                }
                // TODO: check interleaved fragments of different messages
                dctx.state = .hdr2
            case .hdr2:
                b = data[pos]
                pos += 1
                dctx.hdr.mask = (b >> 7) != 0
                dctx.hdr.plen = b & 0x7F
                dctx.hdr.xpl = 0
                dctx.pos = 0
                dctx.buf = []
                if dctx.hdr.opcode.isControl && dctx.hdr.plen > 125 {
                    // the payload length of control frames MUST <= 125
                    dctx.state = .error
                    return .protocolError
                }
                dctx.state = .hdrex
            case .hdrex:
                var expectLen = 0
                if dctx.hdr.plen == 126 {
                    expectLen = 2
                } else if dctx.hdr.plen == 127 {
                    expectLen = 8
                }
                if expectLen > 0 {
                    if len-pos+dctx.pos >= expectLen {
                        while dctx.pos < expectLen {
                            dctx.hdr.xpl |= UInt64(data[pos]) << UInt64((expectLen-dctx.pos-1) << 3)
                            pos += 1
                            dctx.pos += 1
                        }
                        dctx.pos = 0
                        if dctx.hdr.xpl < 126 || (dctx.hdr.xpl >> 63) != 0 {
                            dctx.state = .error
                            return WSError.invalidLength
                        }
                        dctx.hdr.length = Int(dctx.hdr.xpl)
                        if dctx.hdr.length > kWSMaxPayloadSize {
                            dctx.state = .error
                            return WSError.invalidLength
                        }
                        dctx.state = .maskey
                    } else {
                        while pos < len {
                            dctx.hdr.xpl |= UInt64(data[pos]) << UInt64((expectLen-dctx.pos-1) << 3)
                            pos += 1
                            dctx.pos += 1
                        }
                        return WSError.incomplete
                    }
                } else {
                    dctx.hdr.length = Int(dctx.hdr.plen)
                    dctx.state = .maskey
                }
            case .maskey:
                if dctx.hdr.mask {
                    if mode == .client {
                        // server MUST NOT mask any frames
                        dctx.state = .error
                        return .protocolError
                    }
                    let expectLen = 4
                    var copyLen = len - pos
                    if copyLen+dctx.pos > expectLen {
                        copyLen = expectLen-dctx.pos
                    }
                    for _ in 0..<copyLen {
                        dctx.hdr.maskey[dctx.pos] = data[pos]
                        pos += 1
                        dctx.pos += 1
                    }
                    if dctx.pos < expectLen {
                        return WSError.incomplete
                    }
                    dctx.pos = 0
                } else if mode == .server && dctx.hdr.length > 0 {
                    // client MUST mask all frames
                    dctx.state = .error
                    return .protocolError
                }
                dctx.buf = []
                dctx.state = .data
            case .data:
                let remain = len-pos
                if remain+dctx.buf.count < dctx.hdr.length {
                    let copyLen = len - pos
                    let bbuf = UnsafeMutableBufferPointer(start: data+pos, count: copyLen)
                    dctx.buf.append(contentsOf: bbuf)
                    return WSError.incomplete
                }
                
                if dctx.buf.count == 0 {
                    let notifyData = data + pos
                    let notifySize = dctx.hdr.length
                    pos += notifySize
                    handleDataMaskHdr(dctx.hdr, notifyData, notifySize)
                    _ = handleFrame(dctx.hdr, notifyData, notifySize)
                } else {
                    let copyLen = dctx.hdr.length - dctx.buf.count
                    let bbuf = UnsafeMutableBufferPointer(start: data+pos, count: copyLen)
                    dctx.buf.append(contentsOf: bbuf)
                    pos += copyLen
                    dctx.buf.withUnsafeMutableBufferPointer {
                        let ptr = $0.baseAddress
                        handleDataMaskHdr(dctx.hdr, ptr!, dctx.hdr.length)
                        _ = handleFrame(dctx.hdr, ptr!, dctx.hdr.length)
                    }
                }
                if dctx.hdr.opcode == .close {
                    dctx.state = .closed
                    return WSError.closed
                }
                dctx.reset()
            default:
                return WSError.invalidFrame
            }
        }
        return dctx.state == .hdr1 ? .noErr : .incomplete
    }
    
    func handleDataMaskHdr(_ hdr: FrameHeader, _ data: UnsafeMutablePointer<UInt8>, _ len: Int) {
        if !hdr.mask || len == 0 {
            return
        }
        handleDataMask(hdr.maskey, data, len)
    }
    
    func handleFrame(_ hdr: FrameHeader, _ payload: UnsafeMutablePointer<UInt8>?, _ plen: Int) -> WSError {
        cbFrame?(hdr.opcode, hdr.fin, payload, plen)
        return .noErr
    }
    
    func onHttpData(data: UnsafeMutableRawPointer, len: Int) {
        errTrace("WSHandler, onHttpData, len=\(len)")
    }
    
    func onHttpHeaderComplete() {
        
    }
    
    func onHttpComplete() {
        if parser.isRequest {
            handleRequest()
        } else {
            handleResponse()
        }
    }
    
    func onHttpError(err: KMError) {
        state = .error
    }
}

extension WSHandler {
    @discardableResult func onFrame(cb: @escaping WSFrameCallback) -> Self {
        cbFrame = cb
        return self
    }
    
    @discardableResult func onHandshake(cb: @escaping (KMError) -> Void) -> Self {
        cbHandshake = cb
        return self
    }
}

func handleDataMask(_ mkey: [UInt8], _ data: UnsafeMutablePointer<UInt8>, _ len: Int) {
    for i in 0..<len {
        data[i] ^= mkey[i%kWSMaskKeySize]
    }
}

func == (lhs: WSOpcode, rhs: WSOpcode) -> Bool {
    return lhs.code == rhs.code
}
