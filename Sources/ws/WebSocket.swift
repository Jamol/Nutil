//
//  WebSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 12/21/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

let kMaxWsHeaderSize = 10
class WebSocketImpl : TcpConnection, WebSocket {
    fileprivate var handler = WSHandler()
    fileprivate var hdrBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kMaxWsHeaderSize)
    
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
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbConnect: ErrorCallback?
    fileprivate var cbError: ErrorCallback?
    fileprivate var cbSend: EventCallback?
    
    override init() {
        super.init()
        handler
            .onData(cb: self.onWsData)
            .onHandshake(cb: self.onWsHandshake)
    }
    
    deinit {
        hdrBuffer.deallocate(capacity: kMaxWsHeaderSize)
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
        setState(.connecting)
        return connect(host, port)
    }
    
    override func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError {
        setState(.upgrading)
        return super.attachFd(fd, initData, initSize)
    }
    
    func sendData(_ data: UnsafeRawPointer, _ len: Int) -> Int {
        if state != .open {
            return -1
        }
        if !sendBufferEmpty() {
            return 0
        }
        var opcode = WSHandler.WSOpcode.binary
        if handler.getOpcode() == WSHandler.WSOpcode.text.rawValue {
            opcode = WSHandler.WSOpcode.text
        }
        let hdrSize = handler.encodeFrameheader(opcode, len, hdrBuffer)
        let iovs: [iovec] = [
            iovec(iov_base: hdrBuffer, iov_len: hdrSize),
            iovec(iov_base: UnsafeMutableRawPointer(mutating: data), iov_len: len)
        ]
        let ret = super.send(iovs)
        return ret < 0 ? ret : len
    }
    
    override func close() {
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
    
    fileprivate func onWsData(_ data: UnsafeMutableRawPointer, _ len: Int) {
        cbData?(data, len)
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
}

extension WebSocketImpl {
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
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
