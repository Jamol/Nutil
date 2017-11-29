//
//  Http2Request.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class Http2Request : HttpHeader, HttpRequest {
    fileprivate var conn: H2Connection?
    fileprivate var stream: H2Stream?
    
    fileprivate var cbData: DataCallback?
    fileprivate var cbHeader: EventCallback?
    fileprivate var cbComplete: EventCallback?
    fileprivate var cbError: ErrorCallback?
    fileprivate var cbSend: EventCallback?
    
    fileprivate var url: URL!
    fileprivate var method = ""
    fileprivate let objectId = generateObjectId()
    
    fileprivate var writeBlocked = false
    fileprivate var bodyBytesSent = 0
    
    fileprivate var dataList: [[UInt8]?] = []
    
    fileprivate var statusCode = 0
    fileprivate var rspHeaders: [String: String] = [:]
    
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
    
    fileprivate func setState(_ state: State) {
        self.state = state
    }
    
    override func addHeader(_ name: String, _ value: String) {
        if name.caseInsensitiveCompare(kTransferEncoding) == .orderedSame
            && value.caseInsensitiveCompare("chunked") == .orderedSame {
            isChunked = true
            return
        }
        super.addHeader(name, value)
    }
    
    func sendRequest(_ method: String, _ url: String) -> KMError {
        if state == .completed {
            reset() // reuse case
        }
        self.url = URL(string: url)
        self.method = method
        
        guard let host = self.url.host else {
            return .invalidParam
        }
        
        var port = 80
        var sslFlags = SslFlag.none.rawValue
        if self.url.scheme?.caseInsensitiveCompare("https") == .orderedSame {
            port = 443
            sslFlags |= SslFlag.sslDefault.rawValue
        }
        if self.url.port != nil {
            port = self.url.port!
        }
        
        setState(.connecting)
        let connMgr = H2ConnectionMgr.getRequestConnMgr(sslFlags != SslFlag.none.rawValue)
        conn = connMgr.getConnection(host, port, sslFlags)
        if let c = conn {
            c.async {
                let err = self.sendRequest_i()
                if err != .noError {
                    self.onError(err)
                }
            }
        } else {
            errTrace("sendRequest, failed to get H2Connection")
            return .invalidParam
        }
        return .noError
    }
    
    func sendRequest_i() -> KMError {
        guard let c = conn else {
            return .invalidState
        }
        if !c.isReady {
            c.addConnectListener(objectId) { err in
                self.onConnect(err)
            }
            return .noError
        } else {
            return sendHeaders()
        }
    }
    
    func getHeaderValue(_ name: String) -> String? {
        return headers[name]
    }
    
    func checkHeaders() {
        if(!hasHeader("accept")) {
            addHeader("accept", "*/*")
        }
        if(!hasHeader("content-type")) {
            addHeader("content-type", "application/octet-stream")
        }
        if(!hasHeader("user-agent")) {
            addHeader("user-agent", kDefauleUserAgent)
        }
        if(!hasHeader("cache-control")) {
            addHeader("cache-control", "no-cache")
        }
        if(!hasHeader("pragma")) {
            addHeader("pragma", "no-cache")
        }
    }
    
    fileprivate func buildHeaders() -> (headers: NameValueArray, size: Int) {
        processHeader()
        var hdrSize = 0
        var hdrList: [KeyValuePair] = []
        hdrList.append((kH2HeaderMethod, method))
        hdrSize += kH2HeaderMethod.utf8.count + method.utf8.count
        
        var scheme = "http"
        if let s = url.scheme {
            scheme = s
        }
        hdrList.append((kH2HeaderScheme, scheme))
        hdrSize += kH2HeaderScheme.utf8.count + scheme.utf8.count
        
        var u = "/"
        if !url.path.isEmpty {
            u = url.path
        }
        if let query = url.query {
            u += "?" + query
        }
        hdrList.append((kH2HeaderPath, u))
        hdrSize += kH2HeaderPath.utf8.count + u.utf8.count
        
        if let host = url.host {
            hdrList.append((kH2HeaderAuthority, host))
            hdrSize += kH2HeaderAuthority.utf8.count + host.utf8.count
        }
        
        for hdr in headers {
            hdrList.append((hdr.key, hdr.value))
            hdrSize += hdr.key.utf8.count + hdr.value.utf8.count
        }
        
        return (hdrList, hdrSize)
    }
    
    fileprivate func sendHeaders() -> KMError {
        stream = conn?.createStream()
        guard let stream = self.stream else {
            return .invalidState
        }
        stream.onHeaders(onHeaders)
        .onData(onData)
        .onRSTStream(onRSTStream)
        .onWrite(onWrite)
        
        setState(.sendingHeader)
        let hdrInfo = buildHeaders()
        let endStream = contentLength == nil && !isChunked
        let ret = stream.sendHeaders(hdrInfo.headers, hdrInfo.size, endStream)
        if ret == .noError {
            if (endStream) {
                setState(.receivingResponse)
            } else {
                setState(.sendingBody)
                onWrite() // should queue in event loop rather than call onWrite directly?
            }
        }
        return ret
    }
    
    fileprivate func onConnect( _ err: KMError) {
        if err != .noError {
            onError(err)
            return
        }
        _ = sendHeaders()
    }
    
    fileprivate func onError(_ err: KMError) {
        cbError?(err)
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        var dbuf: [UInt8]? = nil
        if let d = data, len > 0 {
            let u8 = d.assumingMemoryBound(to: UInt8.self)
            let bbuf = UnsafeBufferPointer(start: u8, count: len)
            dbuf = Array(bbuf)
        }
        return sendData(dbuf)
    }
    
    func sendData<T>(_ data: [T]?) -> Int {
        guard let conn = self.conn else {
            return -1
        }
        if state != .sendingBody {
            return 0
        }
        if writeBlocked {
            return 0
        }
        var wlen = 0
        if let d = data {
            wlen = d.count * MemoryLayout<T>.size
        }
        conn.async {
            _ = self.sendData_i(data, true)
        }
        return wlen
    }
    
    func sendString(_ str: String) -> Int {
        return sendData(UnsafePointer<UInt8>(str), str.utf8.count)
    }
    
    fileprivate func sendData_i<T>(_ data: [T]?, _ newData: Bool) -> Int {
        if state != .sendingBody {
            return 0
        }
        guard let stream = self.stream else {
            return -1
        }
        if newData && !dataList.isEmpty {
            if let d = data {
                let slen = d.count
                d.withUnsafeBufferPointer {
                    let ptr = $0.baseAddress!
                    ptr.withMemoryRebound(to: UInt8.self, capacity: slen) {
                        let bbuf = UnsafeBufferPointer(start: $0, count: slen)
                        let dbuf = Array(bbuf)
                        dataList.append(dbuf)
                    }
                }
            } else {
                dataList.append(nil)
            }
            return 0
        }
        var ret = 0
        var slen = 0
        if let dbuf = data {
            slen = dbuf.count * MemoryLayout<T>.size
            if let clen = contentLength {
                if bodyBytesSent + slen > clen {
                    slen = clen - bodyBytesSent
                }
            }
            ret = stream.sendData(dbuf, slen, false);
            if (ret > 0) {
                bodyBytesSent += ret
            }
        }
        let endStream = (data == nil) || (contentLength != nil && bodyBytesSent >= contentLength!)
        if endStream {
            _ = stream.sendData(nil, 0, true)
            setState(.receivingResponse)
        }
        if newData, ret == 0, let d = data {
            writeBlocked = true
            d.withUnsafeBufferPointer {
                let ptr = $0.baseAddress!
                ptr.withMemoryRebound(to: UInt8.self, capacity: slen) {
                    let bbuf = UnsafeBufferPointer(start: $0, count: slen)
                    let dbuf = Array(bbuf)
                    dataList.append(dbuf)
                }
            }
            ret = slen
        }
        return ret
    }
    
    fileprivate func sendData_i() -> Int {
        var bytesSent = 0
        while !dataList.isEmpty {
            let ret = sendData_i(dataList[0], false)
            if (ret > 0) {
                bytesSent += ret
                dataList.removeFirst()
            } else if ret == 0 {
                break
            } else {
                onError(.failed)
                return -1
            }
        }
        return bytesSent
    }
    
    fileprivate func onHeaders(headers: NameValueArray, endStream: Bool) {
        (statusCode, rspHeaders) = processH2ResponseHeaders(headers)
        if statusCode < 0 {
            return
        }
        cbHeader?()
        if endStream {
            setState(.completed)
            cbComplete?()
        }
    }
    
    fileprivate func onData(data: UnsafeMutableRawPointer?, len: Int, endStream: Bool) {
        if let d = data, len > 0 {
            cbData?(d, len)
        }
        if endStream {
            setState(.completed)
            cbComplete?()
        }
    }
    
    fileprivate func onRSTStream(err: Int) {
        onError(.failed)
    }
    
    fileprivate func onWrite() {
        if sendData_i() < 0 || !dataList.isEmpty {
            return
        }
        writeBlocked = false
        cbSend?()
    }
    
    func close() {
        if let conn = conn {
            conn.sync {
                if self.state == .completed {
                    conn.removeConnectListener(objectId)
                }
                if let stream = self.stream {
                    stream.close()
                }
            }
        }
        stream = nil
        conn = nil
    }
    
    override func reset() {
        super.reset()
        stream?.close()
        writeBlocked = false
        bodyBytesSent = 0
        statusCode = 0
        rspHeaders = [:]
        dataList = []
        if state == .completed {
            setState(.waitForReuse)
        }
    }
    
    func getStatusCode() -> Int {
        return statusCode
    }
    
    func getHeader(_ name: String) -> String? {
        return rspHeaders[name]
    }
}

extension Http2Request {
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

func processH2ResponseHeaders(_ headers: NameValueArray) -> (Int, [String: String]) {
    if headers.isEmpty {
        return (-1, [:])
    }
    if headers[0].name.compare(kH2HeaderStatus) != .orderedSame {
        return (-1, [:])
    }
    let statusCode = Int(headers[0].value)!
    var rspHeaders: [String : String] = [:]
    var cookie = ""
    for i in 1..<headers.count {
        if headers[i].name.compare(kH2HeaderCookie) == .orderedSame {
            if !cookie.isEmpty {
                cookie += "; "
            }
            cookie += headers[i].value
        } else if !headers[i].name.hasPrefix(":") {
            rspHeaders[headers[i].name] = headers[i].value
        }
    }
    if !cookie.isEmpty {
        rspHeaders["Cookie"] = cookie
    }
    return (statusCode, rspHeaders)
}
