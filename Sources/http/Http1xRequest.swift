//
//  Http1xRequest.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

public class Http1xRequest : TcpConnection, HttpParserDelegate {
    
    public typealias DataCallback = (UnsafeMutableRawPointer, Int) -> Void
    public typealias EventCallback = () -> Void
    
    fileprivate let parser = HttpParser()
    fileprivate var headers: [String: String] = [:]
    fileprivate var contentLength: Int?
    fileprivate var isChunked = false
    fileprivate var url: URL!
    fileprivate var method = ""
    fileprivate var version = "HTTP/1.1"
    fileprivate var bodyBytesSent = 0
    
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
    fileprivate var cbError: EventCallback?
    
    public override init() {
        super.init()
        parser.delegate = self
    }
    
    fileprivate func setState(_ state: State) {
        self.state = state
    }
    
    fileprivate func cleanup() {
        super.close()
    }
    
    public func addHeader(name: String, value: String) {
        if !name.isEmpty {
            if name.caseInsensitiveCompare(kContentLength) == .orderedSame {
                contentLength = Int(value)
            } else if name.caseInsensitiveCompare(kTransferEncoding) == .orderedSame {
                isChunked = value.caseInsensitiveCompare("chunked") == .orderedSame
            }
            headers[name] = value
        }
    }
    
    public func addHeader(name: String, value: Int) {
        addHeader(name: name, value: String(value))
    }
    
    public func sendRequest(method: String, url: String, ver: String) -> KMError {
        self.url = URL(string: url)
        self.method = method
        
        guard let host = self.url.host else {
            return .invalidParam
        }
        
        checkHeaders()
        
        var port = 80
        if self.url.scheme?.caseInsensitiveCompare("https") == .orderedSame {
            port = 443
        }
        if self.url.port != nil {
            port = self.url.port!
        }
        
        setState(.connecting)
        let ret = connect(host, port)
        if ret < 0 {
            setState(.error)
            return .sockError
        }
        return .noError
    }
    
    override public func close() {
        cleanup()
    }
    
    fileprivate func checkHeaders() {
        if headers["Accept"] == nil {
            headers["Accept"] = "*/*"
        }
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/octet-stream"
        }
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = kDefauleUserAgent
        }
        if headers["Cache-Control"] == nil {
            headers["Cache-Control"] = "no-cache"
        }
        if headers["Pragma"] == nil {
            headers["Pragma"] = "no-cache"
        }
        if headers["Host"] == nil {
            headers["Host"] = url.host
        }
    }
    
    private func buildRequest() -> String {
        var req = method
        if !url.path.isEmpty {
            req += " " + url.path
        } else {
            req += " /"
        }
        if let query = url.query {
            req += "?" + query
        }
        req += " " + version
        req += "\r\n"
        for kv in headers {
            req += kv.key + ": " + kv.value + "\r\n"
        }
        req += "\r\n"
        return req
    }
    
    private func sendRequest() {
        bodyBytesSent = 0
        let req = buildRequest()
        setState(.sendingHeader)
        let ret = send(req)
        if ret < 0 {
            errTrace("sendRequest, failed to send request")
            setState(.error)
        } else if isChunked || (contentLength != nil && contentLength! > 0){
            setState(.sendingBody)
        } else {
            setState(.receivingResponse)
        }
    }
    
    override func handleOnConnect(err: KMError) {
        infoTrace("handleOnConnect, err=\(err)")
        if err == .noError {
            sendRequest()
        } else {
            setState(.error)
        }
    }
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        let ret = parser.parse(data: data, len: len)
        if ret != len {
            warnTrace("handleInputData, ret=\(ret), len=\(len)")
        }
        return true
    }
    
    override func handleOnSend() {
        
    }
    
    override func handleOnError(err: KMError) {
        infoTrace("handleOnError, err=\(err)")
        onError()
    }
    
    func onData(data: UnsafeMutableRawPointer, len: Int) {
        //infoTrace("onData, len=\(len), total=\(parser.bodyBytesRead)")
        cbData?(data, len)
    }
    
    func onHeaderComplete() {
        infoTrace("onHeaderComplete")
        cbHeader?()
    }
    
    func onComplete() {
        infoTrace("onComplete, bodyReceived=\(parser.bodyBytesRead)")
        setState(.completed)
        cbComplete?()
    }
    
    func onError() {
        infoTrace("onError")
        if state == .receivingResponse && parser.setEOF(){
            return
        }
        if state < State.completed {
            setState(.error)
            cbError?()
        } else {
            setState(.closed)
        }
    }
}

extension Http1xRequest {
    @discardableResult public func onData(cb: @escaping DataCallback) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult public func onHeaderComplete(cb: @escaping EventCallback) -> Self {
        cbHeader = cb
        return self
    }
    
    @discardableResult public func onComplete(cb: @escaping EventCallback) -> Self {
        cbComplete = cb
        return self
    }
    
    @discardableResult public func onError(cb: @escaping EventCallback) -> Self {
        cbError = cb
        return self
    }
}

