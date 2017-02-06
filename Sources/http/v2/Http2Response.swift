//
//  Http2Response.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

let kColon = UInt8(ascii: ":")

class Http2Response : HttpHeader, HttpResponse {
    fileprivate var stream: H2Stream?
    
    fileprivate var bodyBytesSent = 0
    fileprivate var reqHeaders: [String: String] = [:]
    fileprivate var reqMethod = ""
    fileprivate var reqPath = ""
    fileprivate var version = "HTTP/2.0"
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbHeader: EventCallback?
    fileprivate var cbRequest: EventCallback?
    fileprivate var cbComplete: EventCallback?
    fileprivate var cbError: ErrorCallback?
    fileprivate var cbSend: EventCallback?
    
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
    
    fileprivate func setState(_ state: State) {
        self.state = state
    }
    
    fileprivate func cleanup() {
        if let stream = self.stream {
            stream.close()
            self.stream = nil
        }
    }
    
    func setSslFlags(_ flags: UInt32) {
        
    }
    
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError {
        return .unsupport
    }
    
    func attachStream(_ conn: H2Connection, _ streamId: UInt32) -> KMError {
        stream = conn.getStream(streamId)
        if stream == nil {
            return .invalidParam
        }
        stream!.onHeaders(onHeaders)
            .onData(onData)
            .onRSTStream(onRSTStream)
            .onWrite(onWrite)
        
        return .noError
    }
    
    override func addHeader(_ name: String, _ value: String) {
        if name.caseInsensitiveCompare(kTransferEncoding) == .orderedSame
            && value.caseInsensitiveCompare("chunked") == .orderedSame {
            isChunked = true
            return
        }
        super.addHeader(name, value)
    }
    
    func sendResponse(_ statusCode: Int, _ desc: String?) -> KMError {
        infoTrace("sendResponse, statusCode=\(statusCode)")
        guard let stream = self.stream else {
            return .invalidState
        }
        setState(.sendingHeader)
        let hdrInfo = buildHeaders(statusCode)
        let endStream = contentLength != nil && contentLength! == 0
        let ret = stream.sendHeaders(hdrInfo.headers, hdrInfo.size, endStream)
        if ret == .noError {
            if (endStream) {
                setState(.completed)
                notifyComplete()
            } else {
                setState(.sendingBody)
                onWrite() // should queue in event loop rather than call onWrite directly?
            }
        }
        return ret
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        if state != .sendingBody {
            return 0
        }
        guard let stream = self.stream else {
            return 0
        }
        var ret = 0
        if let dbuf = data, len > 0 {
            var slen = len
            if let clen = contentLength {
                if bodyBytesSent + slen > clen {
                    slen = clen - bodyBytesSent
                }
            }
            ret = stream.sendData(dbuf, slen, false)
            if (ret > 0) {
                bodyBytesSent += ret
            }
        }
        let endStream = (data == nil) || (contentLength != nil && bodyBytesSent >= contentLength!)
        if endStream {
            _ = stream.sendData(nil, 0, true)
            setState(.completed)
            notifyComplete()
        }
        return ret
    }
    
    func sendString(_ str: String) -> Int {
        return sendData(UnsafePointer<UInt8>(str), str.utf8.count)
    }
    
    fileprivate func checkHeaders() {
        
    }
    
    fileprivate func buildHeaders(_ statusCode: Int) -> (headers: NameValueArray, size: Int) {
        processHeader(statusCode)
        var hdrSize = 0
        var hdrList: [KeyValuePair] = []
        let strCode = "\(statusCode)"
        hdrList.append((kH2HeaderStatus, strCode))
        hdrSize += kH2HeaderStatus.utf8.count + strCode.utf8.count

        for hdr in headers {
            hdrList.append((hdr.key, hdr.value))
            hdrSize += hdr.key.utf8.count + hdr.value.utf8.count
        }
        
        return (hdrList, hdrSize)
    }
    
    fileprivate func onHeaders(headers: NameValueArray, endHeaders: Bool, endStream: Bool) {
        if headers.isEmpty {
            return
        }
        for kv in headers {
            if kv.name.isEmpty {
                continue
            }
            if UInt8(kv.name.utf8CString[0]) == kColon {
                if kv.name.compare(kH2HeaderMethod) == .orderedSame {
                    reqMethod = kv.value
                } else if kv.name.compare(kH2HeaderAuthority) == .orderedSame {
                    super.headers["host"] = kv.value
                } else if kv.name.compare(kH2HeaderPath) == .orderedSame {
                    reqPath = kv.value
                }
            } else {
                super.headers[kv.name] = kv.value
            }
        }
        if endHeaders {
            cbHeader?()
        }
        if endStream {
            setState(.waitForResponse)
            cbRequest?()
        }
    }
    
    fileprivate func onData(data: UnsafeMutableRawPointer?, len: Int, endStream: Bool) {
        if let d = data, len > 0 {
            cbData?(d, len)
        }
        if endStream {
            setState(.waitForResponse)
            cbRequest?()
        }
    }
    
    fileprivate func onRSTStream(err: Int) {
        onError(.failed)
    }
    
    fileprivate func onWrite() {
        cbSend?()
    }
    
    fileprivate func onError(_ err: KMError) {
        cbError?(err)
    }
    
    fileprivate func notifyComplete() {
        cbComplete?()
    }
    
    override func reset() {
        super.reset()
    }
    
    func close() {
        infoTrace("Http2Response.close")
        cleanup()
        setState(.closed)
    }
}

extension Http2Response {
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHeaderComplete(_ cb: @escaping () -> Void) -> Self {
        cbHeader = cb
        return self
    }
    
    @discardableResult func onRequestComplete(_ cb: @escaping () -> Void) -> Self {
        cbRequest = cb
        return self
    }
    
    @discardableResult func onResponseComplete(_ cb: @escaping () -> Void) -> Self {
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
    
    func getMethod() -> String {
        return reqMethod
    }
    
    func getPath() -> String {
        return reqPath
    }
    
    func getVersion() -> String {
        return version
    }
    
    func getHeader(_ name: String) -> String? {
        return reqHeaders[name]
    }
    
    func getParam(_ name: String) -> String? {
        return nil
    }
}
