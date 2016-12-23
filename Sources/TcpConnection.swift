//
//  TcpConnection.swift
//  Nutil
//
//  Created by Jamol Bao on 12/9/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

class TcpConnection
{
    fileprivate let kRecvBufferSize = 64*1024
    let socket = AutoScoket()
    fileprivate var buffer = [UInt8]()
    fileprivate var initBuffer: [UInt8]?
    var isServer = false
    
    init() {
        socket
            .onConnect(cb: onConnect)
            .onRead(cb: onRead)
            .onWrite(cb: onWrite)
            .onClose(cb: onClose)
    }
    
    func connect(_ addr: String, _ port: Int) -> KMError {
        isServer = false
        return socket.connect(addr, port)
    }
    
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError {
        isServer = true
        if initData != nil && initSize > 0 {
            let ptr = initData!.assumingMemoryBound(to: UInt8.self)
            let bbuf = UnsafeBufferPointer(start: ptr, count: initSize)
            initBuffer = Array(bbuf)
        }
        return socket.attachFd(fd)
    }
    
    func send(_ str: String) -> Int {
        if !sendBufferEmpty() {
            if !sendBufferedData() {
                return -1
            }
            if !sendBufferEmpty() {
                return 0
            }
        }
        let wlen = str.utf8.count
        let ret = socket.write(str)
        if ret > 0 {
            if ret < wlen {
                let ptr = UnsafePointer<UInt8>(str)
                buffer = Array(UnsafeBufferPointer(start: ptr + ret, count: wlen - ret))
            }
            return wlen
        }
        return ret
    }
    
    func send<T>(_ data: [T]) -> Int {
        if !sendBufferEmpty() {
            if !sendBufferedData() {
                return -1
            }
            if !sendBufferEmpty() {
                return 0
            }
        }
        let wlen = data.count * MemoryLayout<T>.size
        let ret = socket.write(data)
        if ret > 0 {
            if ret < wlen {
                data.withUnsafeBytes {
                    let ptr = $0.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    buffer = Array(UnsafeBufferPointer(start: ptr! + ret, count: wlen - ret))
                }
            }
            return wlen
        }
        return ret
    }
    
    func send(_ data: UnsafeRawPointer, _ len: Int) -> Int {
        if !sendBufferEmpty() {
            if !sendBufferedData() {
                return -1
            }
            if !sendBufferEmpty() {
                return 0
            }
        }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let ret = socket.write(ptr, len)
        if ret > 0 {
            if ret < len {
                buffer = Array(UnsafeBufferPointer(start: ptr + ret, count: len - ret))
            }
            return len
        }
        
        return ret
    }
    
    func send(_ iovs: [iovec]) -> Int {
        if !sendBufferEmpty() {
            if !sendBufferedData() {
                return -1
            }
            if !sendBufferEmpty() {
                return 0
            }
        }
        var ret = socket.writev(iovs)
        if ret >= 0 {
            var wlen = 0
            for iov in iovs {
                wlen += iov.iov_len
                let pfirst = iov.iov_base + ret
                let plast = iov.iov_base + iov.iov_len
                if pfirst < plast {
                    let ptr = pfirst.assumingMemoryBound(to: UInt8.self)
                    buffer += Array(UnsafeBufferPointer(start: ptr, count: plast - pfirst))
                    ret = 0
                } else {
                    ret -= iov.iov_len
                }
            }
            return wlen
        }
        return ret
    }
    
    func close() {
        socket.close()
    }
    
    func handleOnConnect(err: KMError) {
        
    }
    
    func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        fatalError("MUST Override handleInputData")
    }
    
    func handleOnSend() {
        _ = sendBufferedData()
    }
    
    func handleOnError(err: KMError) {
        
    }
    
    fileprivate func cleanup() {
        socket.close()
    }
    
    func sendBufferEmpty() -> Bool {
        return buffer.count == 0
    }
    
    fileprivate func sendBufferedData() -> Bool {
        if !buffer.isEmpty {
            let ret = socket.write(buffer)
            if ret < 0 {
                return false
            }
            if ret >= buffer.count {
                buffer = []
            } else if ret > 0 { // write partial data
                buffer = Array(buffer[ret..<buffer.count])
            }
        }
        return true
    }
}

extension TcpConnection
{
    fileprivate func onConnect(err: KMError) {
        handleOnConnect(err: err)
    }
    
    fileprivate func onRead() {
        if var ibuf = initBuffer {
            let ilen = ibuf.count
            let ret = ibuf.withUnsafeMutableBufferPointer {
                handleInputData($0.baseAddress!, ilen)
            }
            initBuffer = nil
            if !ret {
                return
            }
        }
        var buf = Array<UInt8>(repeating: 0, count: kRecvBufferSize)
        buf.withUnsafeMutableBufferPointer() {
            guard let ptr = $0.baseAddress else {
                return
            }
            repeat {
                let ret = socket.read(ptr, kRecvBufferSize)
                if ret > 0 {
                    if !handleInputData(ptr, ret) {
                        break
                    }
                } else if ret == 0 {
                    break
                } else {
                    cleanup()
                    handleOnError(err: .sockError)
                }
            }while(true)
        }
    }
    
    fileprivate func onWrite() {
        if !sendBufferedData() {
            return
        }
        if sendBufferEmpty() {
            handleOnSend()
        }
    }
    
    fileprivate func onClose() {
        cleanup()
        handleOnError(err: .sockError)
    }
}
