//
//  Http1xResponse.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

class Http1xResponse : TcpConnection, HttpResponse, HttpParserDelegate, MessageSender {
    
    fileprivate let parser = HttpParser()
    fileprivate var version = "HTTP/1.1"
    
    enum State: Int, Comparable {
        case idle
        case receivingRequest
        case waitForResponse
        case sendingHeader
        case sendingBody
        case completed
        case error
        case closed
    }
    
    fileprivate var state = State.idle
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbHeader: EventCallback?
    fileprivate var cbRequest: EventCallback?
    fileprivate var cbReponse: EventCallback?
    fileprivate var cbError: EventCallback?
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
    
    func attachFd(_ fd: SOCKET_FD) -> Bool {
        let ret = super.attachFd(fd)
        return ret == 0
    }
    
    func addHeader(name: String, value: String) {
        message.addHeader(name: name, value: value)
    }
    
    func addHeader(name: String, value: Int) {
        message.addHeader(name: name, value: value)
    }
    
    func sendResponse(statusCode: Int, desc: String) -> KMError {
        if state != .waitForResponse {
            return .invalidState
        }
        let rsp = message.buildMessageHeader(statusCode: statusCode, desc: desc, ver: version)
        setState(.sendingHeader)
        let ret = send(rsp)
        if ret < 0 {
            errTrace("Http1xResponse.sendResponse, failed to send response")
            setState(.error)
            return .sockError
        } else if sendBufferEmpty() {
            if message.hasBody {
                setState(.sendingBody)
                socket.async {
                    self.cbSend?()
                }
            } else {
                setState(.completed)
                socket.async {
                    self.cbReponse?()
                }
            }
        }
        return .noError
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        if !sendBufferEmpty() || state != .sendingBody {
            return 0
        }
        let ret = message.sendData(data, len)
        if ret >= 0 {
            if message.isCompleted && sendBufferEmpty() {
                setState(.completed)
                socket.async {
                    self.cbReponse?()
                }
            }
        } else if ret < 0 {
            setState(.error)
        }
        return ret
    }
    
    func sendString(_ str: String) -> Int {
        return sendData(UnsafePointer<UInt8>(str), str.utf8.count)
    }
    
    override func close() {
        cleanup()
    }
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        let ret = parser.parse(data: data, len: len)
        if ret != len {
            warnTrace("Http1xResponse.handleInputData, ret=\(ret), len=\(len)")
        }
        return true
    }
    
    override func handleOnSend() {
        if state == .sendingHeader {
            if message.hasBody {
                setState(.sendingBody)
            } else {
                setState(.completed)
                cbReponse?()
                return
            }
            cbSend?()
        } else if state == .sendingBody {
            if message.isCompleted {
                setState(.completed)
                cbReponse?()
                return
            }
            cbSend?()
        }
    }
    
    override func handleOnError(err: KMError) {
        infoTrace("Http1xResponse.handleOnError, err=\(err)")
        onError()
    }
    
    func onData(data: UnsafeMutableRawPointer, len: Int) {
        //infoTrace("onData, len=\(len), total=\(parser.bodyBytesRead)")
        cbData?(data, len)
    }
    
    func onHeaderComplete() {
        infoTrace("Http1xResponse.onHeaderComplete")
        cbHeader?()
    }
    
    func onComplete() {
        infoTrace("Http1xResponse.onRequestComplete, bodyReceived=\(parser.bodyBytesRead)")
        setState(.waitForResponse)
        cbRequest?()
    }
    
    func onError() {
        infoTrace("Http1xResponse.onError")
        if state < State.completed {
            setState(.error)
            cbError?()
        } else {
            setState(.closed)
        }
    }
}

extension Http1xResponse {
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHeaderComplete(cb: @escaping () -> Void) -> Self {
        cbHeader = cb
        return self
    }
    
    @discardableResult func onRequestComplete(cb: @escaping () -> Void) -> Self {
        cbRequest = cb
        return self
    }
    
    @discardableResult func onResponseComplete(cb: @escaping () -> Void) -> Self {
        cbReponse = cb
        return self
    }
    
    @discardableResult func onError(cb: @escaping () -> Void) -> Self {
        cbError = cb
        return self
    }
    
    @discardableResult func onSend(cb: @escaping () -> Void) -> Self {
        cbSend = cb
        return self
    }
    
    func getMethod() -> String {
        return parser.method
    }
    
    func getUrl() -> String {
        return parser.urlString
    }
    
    func getPath() -> String {
        return parser.url.path
    }
    
    func getHeader(name: String) -> String? {
        return parser.headers[name]
    }
    
    func getParam(name: String) -> String? {
        return nil
    }
}
