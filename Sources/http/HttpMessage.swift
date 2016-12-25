//
//  HttpMessage.swift
//  Nutil
//
//  Created by Jamol Bao on 12/19/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

protocol MessageSender {
    func send(_ str: String) -> Int
    func send<T>(_ data: [T]) -> Int
    func send(_ data: UnsafeRawPointer, _ len: Int) -> Int
    func send(_ iovs: [iovec]) -> Int
}

class HttpMessage {
    var isRequest = true
    var headers: [String: String] = [:]
    var contentLength: Int?
    var isChunked = false
    var bodyBytesSent = 0
    fileprivate var statusCode = 0
    fileprivate var completed = false
    
    var isCompleted: Bool { return completed }
    var hasBody: Bool {
        if isChunked {
            return true
        }
        if let clen = contentLength {
            return clen > 0
        }
        if isRequest {
            return false
        }
        return !((100 <= statusCode && statusCode <= 199) ||
            204 == statusCode || 304 == statusCode)
    }
    
    var sender: MessageSender!
    
    func addHeader(name: String, value: String) {
        if !name.isEmpty {
            if name.caseInsensitiveCompare(kContentLength) == .orderedSame {
                contentLength = Int(value)
            } else if name.caseInsensitiveCompare(kTransferEncoding) == .orderedSame {
                isChunked = value.caseInsensitiveCompare("chunked") == .orderedSame
            }
            headers[name] = value
        }
    }
    
    func addHeader(name: String, value: Int) {
        addHeader(name: name, value: String(value))
    }
    
    func hasHeader(name: String) -> Bool {
        return headers[name] != nil
    }
    
    func buildMessageHeader(method: String, url: String, ver: String) -> String {
        isRequest = true
        var req = method + " " + url + " " + ver
        req += "\r\n"
        for kv in headers {
            req += kv.key + ": " + kv.value + "\r\n"
        }
        req += "\r\n"
        return req
    }
    
    func buildMessageHeader(statusCode: Int, desc: String, ver: String) -> String {
        isRequest = false
        self.statusCode = statusCode
        var rsp = "\(ver) \(statusCode)"
        if (!desc.isEmpty) {
            rsp += " " + desc
        }
        rsp += "\r\n"
        for kv in headers {
            rsp += kv.key + ": " + kv.value + "\r\n"
        }
        rsp += "\r\n"
        return rsp
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        if isChunked {
            return sendChunk(data, len)
        }
        guard let d = data else {
            return 0
        }
        let ret = sender.send(d, len)
        if ret > 0 {
            bodyBytesSent += ret
            if contentLength != nil && bodyBytesSent >= contentLength! {
                completed = true
            }
        }
        return ret
    }
    
    fileprivate func sendChunk(_ data: UnsafeRawPointer?, _ len: Int) -> Int {
        if data == nil && len == 0 {
            let endChunk = "0\r\n\r\n"
            let ret = sender.send(endChunk)
            if ret > 0 {
                completed = true
                return 0
            }
            return ret
        } else {
            var str = String(len, radix: 16) + "\r\n"
            let ret = str.withCString { (ptr) -> Int in
                var iovs: [iovec] = []
                var iov = iovec(iov_base: UnsafeMutablePointer<Int8>(mutating: ptr), iov_len: str.utf8.count)
                iovs.append(iov)
                iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: data), iov_len: len)
                iovs.append(iov)
                iov = iovec(iov_base: UnsafeMutablePointer<UInt8>(mutating: kCRLF), iov_len: 2)
                iovs.append(iov)
                return sender.send(iovs)
            }
            if ret > 0 {
                bodyBytesSent += len
                return len
            }
            return ret
        }
    }
    
    func reset() {
        headers.removeAll()
        contentLength = nil
        isChunked = false
        bodyBytesSent = 0
        statusCode = 0
        completed = false
    }
}

let kCRLF = "\r\n".utf8.map { UInt8($0) }
