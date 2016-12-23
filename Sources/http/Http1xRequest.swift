//
//  Http1xRequest.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

class Http1xRequest : TcpConnection, HttpRequest, HttpParserDelegate, MessageSender {

    fileprivate let parser = HttpParser()
    fileprivate var url: URL!
    fileprivate var method = ""
    fileprivate var version = "HTTP/1.1"
    
    enum State: Int, Comparable {
        case idle
        case connecting
        case sendingHeader
        case sendingBody
        case receivingResponse
        case completed
        case error
        case closed
    }
    
    fileprivate var state = State.idle
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbHeader: EventCallback?
    fileprivate var cbComplete: EventCallback?
    fileprivate var cbError: ErrorCallback?
    fileprivate var cbSend: EventCallback?
    
    fileprivate var message = HttpMessage()
    
    override init() {
        super.init()
        parser.delegate = self
        message.sender = self
    }
    
    convenience init(version: String) {
        self.init()
        self.version = version
    }
    
    fileprivate func setState(_ state: State) {
        self.state = state
    }
    
    fileprivate func cleanup() {
        super.close()
    }
    
    func addHeader(name: String, value: String) {
        message.addHeader(name: name, value: value)
    }
    
    func addHeader(name: String, value: Int) {
        message.addHeader(name: name, value: value)
    }
    
    func sendRequest(method: String, url: String) -> KMError {
        infoTrace("Http1xRequest.sendRequest, method=\(method), url=\(url)")
        self.url = URL(string: url)
        self.method = method
        
        guard let host = self.url.host else {
            return .invalidParam
        }
        
        checkHeaders()
        
        var port = 80
        var sslFlags = SslFlag.none.rawValue
        if self.url.scheme?.caseInsensitiveCompare("https") == .orderedSame {
            port = 443
            sslFlags = super.socket.getSslFlags() | SslFlag.sslDefault.rawValue
        }
        if self.url.port != nil {
            port = self.url.port!
        }
        super.socket.setSslFlags(flags: sslFlags)
        setState(.connecting)
        return connect(host, port)
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        if !sendBufferEmpty() || state != .sendingBody {
            return 0
        }
        let ret = message.sendData(data, len)
        if ret >= 0 {
            if message.isCompleted && sendBufferEmpty() {
                setState(.receivingResponse)
            }
        } else if ret < 0 {
            setState(.error)
        }
        return ret
    }
    
    func sendString(_ str: String) -> Int {
        return sendData(UnsafePointer<UInt8>(str), str.utf8.count)
    }
    
    func reset() {
        parser.reset()
        message.reset()
        setState(.idle)
    }
    
    override func close() {
        cleanup()
    }
    
    func getStatusCode() -> Int {
        return parser.statusCode
    }
    
    func getHeader(name: String) -> String? {
        return parser.headers[name]
    }
    
    fileprivate func checkHeaders() {
        if !message.hasHeader(name: "Accept") {
            addHeader(name: "Accept", value: "*/*")
        }
        if !message.hasHeader(name: "Content-Type") {
            addHeader(name: "Content-Type", value: "application/octet-stream")
        }
        if !message.hasHeader(name: "User-Agent") {
            addHeader(name: "User-Agent", value: kDefauleUserAgent)
        }
        if !message.hasHeader(name: "Cache-Control") {
            addHeader(name: "Cache-Control", value: "no-cache")
        }
        if !message.hasHeader(name: "Pragma") {
            addHeader(name: "Pragma", value: "no-cache")
        }
        if !message.hasHeader(name: "Host") {
            addHeader(name: "Host", value: url.host!)
        }
    }
    
    private func sendRequest() {
        var u = "/"
        if !url.path.isEmpty {
            u = url.path
        }
        if let query = url.query {
            u += "?" + query
        }
        let req = message.buildMessageHeader(method: method, url: u, ver: version)
        setState(.sendingHeader)
        let ret = send(req)
        if ret < 0 {
            errTrace("Http1xRequest.sendRequest, failed to send request")
            setState(.error)
        } else if sendBufferEmpty() {
            if message.hasBody {
                setState(.sendingBody)
                cbSend?()
            } else {
                setState(.receivingResponse)
            }
        }
    }
    
    override func handleOnConnect(err: KMError) {
        infoTrace("Http1xRequest.handleOnConnect, err=\(err)")
        if err == .noError {
            sendRequest()
        } else {
            setState(.error)
        }
    }
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        let ret = parser.parse(data: data, len: len)
        if ret != len {
            warnTrace("Http1xRequest.handleInputData, ret=\(ret), len=\(len)")
        }
        return true
    }
    
    override func handleOnSend() {
        if state == .sendingHeader {
            if message.hasBody {
                setState(.sendingBody)
            } else {
                setState(.receivingResponse)
                return
            }
        } else if state == .sendingBody {
            if message.isCompleted {
                setState(.receivingResponse)
                return
            }
        }
        cbSend?()
    }
    
    override func handleOnError(err: KMError) {
        infoTrace("Http1xRequest.handleOnError, err=\(err)")
        onError(err: err)
    }
    
    func onData(data: UnsafeMutableRawPointer, len: Int) {
        //infoTrace("onData, len=\(len), total=\(parser.bodyBytesRead)")
        cbData?(data, len)
    }
    
    func onHeaderComplete() {
        infoTrace("Http1xRequest.onHeaderComplete")
        cbHeader?()
    }
    
    func onComplete() {
        infoTrace("Http1xRequest.onResponseComplete, bodyReceived=\(parser.bodyBytesRead)")
        setState(.completed)
        cbComplete?()
    }
    
    func onError(err: KMError) {
        infoTrace("Http1xRequest.onError")
        if state == .receivingResponse && parser.setEOF(){
            return
        }
        if state < State.completed {
            setState(.error)
            cbError?(err)
        } else {
            setState(.closed)
        }
    }
}

extension Http1xRequest {
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHeaderComplete(cb: @escaping () -> Void) -> Self {
        cbHeader = cb
        return self
    }
    
    @discardableResult func onRequestComplete(cb: @escaping () -> Void) -> Self {
        cbComplete = cb
        return self
    }
    
    @discardableResult func onError(cb: @escaping (KMError) -> Void) -> Self {
        cbError = cb
        return self
    }
    
    @discardableResult func onSend(cb: @escaping () -> Void) -> Self {
        cbSend = cb
        return self
    }
}
