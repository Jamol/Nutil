//
//  WSHandler.swift
//  Nutil
//
//  Created by Jamol Bao on 12/21/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

let kMaxFrameDataLength = 10*1024*1024

enum WSError {
    case noErr
    case incomplete
    case handshake
    case invalidParam
    case invalidState
    case invalidFrame
    case invalidLength
    case closed
}

class WSHandler : HttpParserDelegate {
    enum WSOpcode: UInt8 {
        case _continue_ = 0
        case text   = 1
        case binary = 2
        case closed = 8
        case ping   = 9
        case pong   = 10
    }
    
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
        var opcode: UInt8 = 0
        var mask = false
        var plen: UInt8 = 0
        var xpl: UInt64 = 0
        var maskey: [UInt8] = [0, 0, 0, 0]
        var length = 0
        
        mutating func reset() {
            fin = false
            opcode = 0
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
    fileprivate var opcode: UInt8 = WSOpcode.binary.rawValue
    
    fileprivate var parser = HttpParser()
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbHandshake: ErrorCallback?
    
    init() {
        parser.delegate = self
    }
    
    func getOpcode() -> UInt8 {
        return opcode
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
        if protos != nil && !protos!.isEmpty {
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
    
    func encodeFrameheader(_ opcode: WSOpcode, _ frameSize: Int, _ hdrBuffer: UnsafeMutablePointer<UInt8>) -> Int {
        let firstByte: UInt8 = UInt8(0x80) | opcode.rawValue
        var secondByte: UInt8 = 0
        var hdrSize: UInt8 = 2
        if frameSize <= 125 {
            secondByte = UInt8(frameSize)
        } else if frameSize <= 0xFFFF {
            hdrSize += 2
            secondByte = 126
        } else {
            hdrSize += 8
            secondByte = 127
        }
        hdrBuffer[0] = firstByte
        hdrBuffer[1] = secondByte
        if secondByte == 126 {
            hdrBuffer[2] = UInt8((frameSize >> 8) & 0xFF)
            hdrBuffer[3] = UInt8(frameSize & 0xFF)
        } else if secondByte == 127 {
            hdrBuffer[2] = 0
            hdrBuffer[3] = 0
            hdrBuffer[4] = 0
            hdrBuffer[5] = 0
            hdrBuffer[6] = UInt8((frameSize >> 24) & 0xFF)
            hdrBuffer[7] = UInt8((frameSize >> 16) & 0xFF)
            hdrBuffer[8] = UInt8((frameSize >> 8) & 0xFF)
            hdrBuffer[9] = UInt8(frameSize & 0xFF)
        }
        return Int(hdrSize)
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
                dctx.hdr.opcode = b & 0x0F
                if (b & 0x70) != 0 {
                    dctx.state = .error
                    return .invalidFrame
                }
                opcode = dctx.hdr.opcode
                dctx.state = .hdr2
            case .hdr2:
                b = data[pos]
                pos += 1
                dctx.hdr.mask = (b >> 7) != 0
                dctx.hdr.plen = b & 0x7F
                dctx.hdr.xpl = 0
                dctx.pos = 0
                dctx.buf = []
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
                        if dctx.hdr.length > kMaxFrameDataLength {
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
                }
                dctx.buf = []
                dctx.state = .data
                if dctx.hdr.opcode == WSOpcode.closed.rawValue && dctx.hdr.length == 0 {
                    // connection closed
                    dctx.state = .closed
                    return WSError.closed
                }
            case .data:
                if dctx.hdr.opcode == WSOpcode.closed.rawValue {
                    // connection closed
                    dctx.state = .closed
                    return WSError.closed
                }
                let remain = len-pos
                if dctx.buf.count == 0 && remain >= dctx.hdr.length {
                    let notifyData = data + pos
                    let notifySize = dctx.hdr.length
                    pos += notifySize
                    handleDataMask(dctx.hdr, notifyData, notifySize)
                    cbData?(notifyData, notifySize)
                    dctx.reset()
                } else if remain+dctx.buf.count >= dctx.hdr.length {
                    let copyLen = dctx.hdr.length - dctx.buf.count
                    let bbuf = UnsafeMutableBufferPointer(start: data+pos, count: copyLen)
                    dctx.buf.append(contentsOf: bbuf)
                    pos += copyLen
                    dctx.buf.withUnsafeMutableBufferPointer {
                        let ptr = $0.baseAddress
                        handleDataMask(dctx.hdr, ptr!, dctx.hdr.length)
                        cbData?(ptr!, dctx.hdr.length)
                    }
                    dctx.reset()
                } else {
                    let copyLen = len - pos
                    let bbuf = UnsafeMutableBufferPointer(start: data+pos, count: copyLen)
                    dctx.buf.append(contentsOf: bbuf)
                    return WSError.incomplete
                }
            default:
                return WSError.invalidFrame
            }
        }
        return dctx.state == .hdr1 ? .noErr : .incomplete
    }
    
    func handleDataMask(_ hdr: FrameHeader, _ data: UnsafeMutablePointer<UInt8>, _ len: Int) {
        if !hdr.mask || len == 0 {
            return
        }
        for i in 0..<len {
            data[i] ^= hdr.maskey[i%4]
        }
    }
    
    func onData(data: UnsafeMutableRawPointer, len: Int) {
        errTrace("WSHandler, onHttpData, len=\(len)")
    }
    
    func onHeaderComplete() {
        
    }
    
    func onComplete() {
        if parser.isRequest {
            handleRequest()
        } else {
            handleResponse()
        }
    }
    
    func onError(err: KMError) {
        state = .error
    }
}

extension WSHandler {
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHandshake(cb: @escaping (KMError) -> Void) -> Self {
        cbHandshake = cb
        return self
    }
}
