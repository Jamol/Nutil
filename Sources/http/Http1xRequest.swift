//
//  Http1xRequest.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

public class Http1xRequest : TcpConnection, HttpParserDelegate {
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
        infoTrace("onData, len=\(len)")
    }
    
    func onHeaderComplete() {
        infoTrace("onHeaderComplete")
    }
    
    func onComplete() {
        infoTrace("onComplete")
        setState(.completed)
    }
    
    func onError() {
        infoTrace("onError")
        if state == .receivingResponse && parser.setEOF(){
            return
        }
        if state < State.completed {
            setState(.error)
        } else {
            setState(.closed)
        }
    }
}

// func < for enums
func <<T: RawRepresentable>(a: T, b: T) -> Bool where T.RawValue: Comparable {
    return a.rawValue < b.rawValue
}

