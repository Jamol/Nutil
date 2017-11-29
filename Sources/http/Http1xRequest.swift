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
        case waitForReuse
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
    
    func addHeader(_ name: String, _ value: String) {
        message.addHeader(name, value)
    }
    
    func addHeader(_ name: String, _ value: Int) {
        message.addHeader(name, value)
    }
    
    func sendRequest(_ method: String, _ url: String) -> KMError {
        infoTrace("Http1xRequest.sendRequest, method=\(method), url=\(url)")
        if state == .completed {
            reset() // reuse case
        }
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
        super.socket.setSslFlags(sslFlags)
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
    
    override func reset() {
        super.reset()
        parser.reset()
        message.reset()
        if state == .completed {
            setState(.waitForReuse)
        }
    }
    
    override func close() {
        cleanup()
    }
    
    func getStatusCode() -> Int {
        return parser.statusCode
    }
    
    func getHeader(_ name: String) -> String? {
        return parser.headers[name]
    }
    
    fileprivate func checkHeaders() {
        if !message.hasHeader("Accept") {
            addHeader("Accept", "*/*")
        }
        if !message.hasHeader("Content-Type") {
            addHeader("Content-Type", "application/octet-stream")
        }
        if !message.hasHeader("User-Agent") {
            addHeader("User-Agent", kDefauleUserAgent)
        }
        if !message.hasHeader("Cache-Control") {
            addHeader("Cache-Control", "no-cache")
        }
        if !message.hasHeader("Pragma") {
            addHeader("Pragma", "no-cache")
        }
        if !message.hasHeader("Host") {
            addHeader("Host", url.host!)
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
        let req = message.buildHeader(method, u, version)
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
        onHttpError(err: err)
    }
    
    func onHttpData(data: UnsafeMutableRawPointer, len: Int) {
        //infoTrace("onData, len=\(len), total=\(parser.bodyBytesRead)")
        cbData?(data, len)
    }
    
    func onHttpHeaderComplete() {
        infoTrace("Http1xRequest.onHeaderComplete")
        cbHeader?()
    }
    
    func onHttpComplete() {
        infoTrace("Http1xRequest.onResponseComplete, bodyReceived=\(parser.bodyBytesRead)")
        setState(.completed)
        cbComplete?()
    }
    
    func onHttpError(err: KMError) {
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
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHeaderComplete(_ cb: @escaping () -> Void) -> Self {
        cbHeader = cb
        return self
    }
    
    @discardableResult func onRequestComplete(_ cb: @escaping () -> Void) -> Self {
        cbComplete = cb
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
