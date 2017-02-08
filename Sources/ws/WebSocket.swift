//
//  WebSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 12/21/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

typealias WSDataCallback = (UnsafeMutableRawPointer?, Int, Bool/*isText*/, Bool/*fin*/) -> Void
class WebSocketImpl : TcpConnection, WebSocket {
    fileprivate var handler = WSHandler()
    fileprivate var hdrBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kWSMaxHeaderSize)
    
    enum State {
        case idle
        case connecting
        case upgrading
        case open
        case error
        case closed
    }
    fileprivate var state = State.idle
    fileprivate var url: URL!
    fileprivate var proto = ""
    fileprivate var origin = ""
    
    fileprivate var bytesSent = 0
    fileprivate var fragmented = false
    
    fileprivate var cbData: WSDataCallback?
    fileprivate var cbConnect: ErrorCallback?
    fileprivate var cbError: ErrorCallback?
    fileprivate var cbSend: EventCallback?
    
    override init() {
        super.init()
        handler
            .onFrame(cb: self.onWsFrame)
            .onHandshake(cb: self.onWsHandshake)
    }
    
    deinit {
        hdrBuffer.deallocate(capacity: kWSMaxHeaderSize)
    }
    
    fileprivate func cleanup() {
        super.close()
    }
    
    func setState(_ state: State) {
        self.state = state
    }
    
    func setProtocol(proto: String) {
        self.proto = proto
    }
    
    func setOrigin(origin: String) {
        self.origin = origin
    }
    
    func connect(_ ws_url: String, _ cb: @escaping (KMError) -> Void) -> KMError {
        if state != .idle {
            return .invalidState
        }
        self.url = URL(string: ws_url)
        if url == nil {
            return .invalidParam
        }
        
        guard let host = self.url.host else {
            return .invalidParam
        }
        
        var port = 80
        var sslFlags = SslFlag.none.rawValue
        if self.url.scheme?.caseInsensitiveCompare("wss") == .orderedSame {
            port = 443
            sslFlags = super.socket.getSslFlags() | SslFlag.sslDefault.rawValue
        }
        if self.url.port != nil {
            port = self.url.port!
        }
        
        super.socket.setSslFlags(sslFlags)
        cbConnect = cb
        handler.mode = .client
        setState(.connecting)
        return connect(host, port)
    }
    
    override func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError {
        handler.mode = .server
        setState(.upgrading)
        return super.attachFd(fd, initData, initSize)
    }
    
    func sendData(_ data: UnsafeRawPointer, _ len: Int, _ isText: Bool, _ fin: Bool) -> Int {
        if state != .open {
            return -1
        }
        if !sendBufferEmpty() {
            return 0
        }
        var opcode = WSOpcode.binary
        if isText {
            opcode = .text
        }
        if fin {
            if fragmented {
                fragmented = false
                opcode = ._continue_
            }
        } else {
            if fragmented {
                opcode = ._continue_
            }
            fragmented = true
        }
        let payload = UnsafeMutableRawPointer(mutating: data)
        let ret = sendWsFrame(opcode, fin, payload, len)
        return ret == .noError ? len : -1
    }
    
    override func close() {
        if state == .open {
            _ = sendCloseFrame(1000)
        }
        cleanup()
        setState(.closed)
    }
    
    override func handleOnConnect(err: KMError) {
        infoTrace("WebSocket.handleOnConnect, err=\(err)")
        if err != .noError {
            cbConnect?(err)
            return
        }
        bytesSent = 0
        sendUpgradeRequest()
    }
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        if state == .open || state == .upgrading {
            let ret = handler.handleInputData(data, len)
            if state == .error || state == .closed {
                return false
            }
            if ret != WSError.noErr && ret != .incomplete {
                cleanup()
                setState(.closed)
                cbError?(.failed)
                return false
            }
        } else {
            warnTrace("WebSocket.handleInputData, invalid state: \(state)")
        }
        return true
    }
    
    override func handleOnSend() {
        if state == .upgrading {
            if isServer {
                onStateOpen() // response is sent out
            } else {
                return // wait for upgrade response
            }
        }
        cbSend?()
    }
    
    override func handleOnError(err: KMError) {
        infoTrace("WebSocket.handleOnError, err=\(err)")
        cleanup()
        setState(.error)
        cbError?(err)
    }
    
    fileprivate func sendUpgradeRequest() {
        let req = handler.buildUpgradeRequest(url.path, url.host!, proto, origin)
        setState(.upgrading)
        _ = super.send(req)
    }
    
    fileprivate func sendUpgradeResponse() {
        let rsp = handler.buildUpgradeResponse()
        setState(.upgrading)
        let ret = super.send(rsp)
        if ret == rsp.utf8.count {
            onStateOpen()
        }
    }
    
    fileprivate func onStateOpen() {
        infoTrace("WebSocket.onStateOpen")
        setState(.open)
        if isServer {
            cbSend?()
        } else {
            cbConnect?(.noError)
        }
    }
    
    fileprivate func onWsFrame(_ opcode: WSOpcode, _ fin:Bool, _ payload: UnsafeMutableRawPointer?, _ plen: Int) {
        switch opcode {
        case .text, .binary:
            cbData?(payload, plen, opcode == .text, fin)
        case .close:
            var statusCode: UInt16 = 0
            if plen >= 2 {
                let ptr = payload!.assumingMemoryBound(to: UInt8.self)
                statusCode = decode_u16(ptr)
                infoTrace("WebSocket.onWsFrame, close-frame, statusCode=\(statusCode), plen=\(plen)")
            } else {
                infoTrace("WebSocket.onWsFrame, close-frame received")
            }
            _ = sendCloseFrame(statusCode)
            cleanup()
            setState(.error)
            cbError?(.failed)
        case .ping:
            _ = sendPongFrame(payload, plen)
        case .invalid(let code):
            warnTrace("WebSocket.onWsFrame, invalid opcode: \(code)")
        default:
            break
        }
    }
    
    fileprivate func onWsHandshake(_ err: KMError) {
        if err == .noError {
            if isServer {
                sendUpgradeResponse()
            } else {
                onStateOpen()
            }
        } else {
            setState(.error)
            cbError?(.invalidProto)
        }
    }
    
    func sendWsFrame(_ opcode: WSOpcode, _ fin: Bool, _ payload: UnsafeMutableRawPointer?, _ plen: Int) -> KMError {
        var hdrSize = 0;
        if handler.mode == .client && plen > 0 {
            var mkey = [UInt8](repeating: 0, count: kWSMaskKeySize)
            _ = generateRandomBytes(&mkey, mkey.count)
            let ptr = payload!.assumingMemoryBound(to: UInt8.self)
            handleDataMask(mkey, ptr, plen)
            hdrSize = handler.encodeFrameHeader(opcode, fin, mkey, plen, hdrBuffer)
        } else {
            hdrSize = handler.encodeFrameHeader(opcode, fin, nil, plen, hdrBuffer)
        }
        var iovs: [iovec] = [
            iovec(iov_base: hdrBuffer, iov_len: hdrSize)
        ]
        if plen > 0 {
            iovs.append(iovec(iov_base: payload, iov_len: plen))
        }
        let ret = super.send(iovs)
        if ret < 0 {
            return .sockError
        }
        return .noError
    }
    
    func sendCloseFrame(_ statusCode: UInt16) -> KMError {
        if statusCode != 0 {
            var payload = [UInt8](repeating: 0, count: 2)
            encode_u16(&payload, statusCode)
            return sendWsFrame(.close, true, &payload, 2)
        } else {
            return sendWsFrame(.close, true, nil, 0)
        }
    }
    
    func sendPingFrame(_ payload: UnsafeMutableRawPointer?, _ plen: Int) -> KMError {
        return sendWsFrame(.ping, true, payload, plen)
    }
    
    func sendPongFrame(_ payload: UnsafeMutableRawPointer?, _ plen: Int) -> KMError {
        return sendWsFrame(.pong, true, payload, plen)
    }
}

extension WebSocketImpl {
    @discardableResult func onData(_ cb: @escaping WSDataCallback) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onError(_ cb: @escaping (KMError) -> Void) -> Self {
        cbError = cb
        return self
    }
    
    @discardableResult func onSend(_ cb: @escaping () -> Void) -> Self {
        cbSend = cb
        return self
    }
}
