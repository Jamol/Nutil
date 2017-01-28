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

class HttpMessage : HttpHeader {
    var bodyBytesSent = 0
    fileprivate var completed = false
    
    var isCompleted: Bool { return completed }
    
    var sender: MessageSender!
    
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
    
    override func reset() {
        super.reset()
        bodyBytesSent = 0
        completed = false
    }
}

let kCRLF = "\r\n".utf8.map { UInt8($0) }
