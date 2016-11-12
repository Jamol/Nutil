//
//  TcpSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation
import Darwin

public protocol TcpDelegate {
    func onConnect(_ err: KMError)
    func onRead()
    func onWrite()
    func onClose()
}

public class TcpSocket : Socket
{
    public var delegate: TcpDelegate? = nil
    fileprivate var ssaddr = sockaddr_storage()
    
    enum SocketState {
        case idle
        case connecting
        case open
        case closed
    }
    
    var state: SocketState = .idle
    public var isOpen: Bool { return state == .open }
    
    public init () {
        super.init(queue: nil)
    }
    
    public override init (queue: DispatchQueue?) {
        super.init(queue: queue)
    }
    
    deinit {
        
    }
    
    override internal func processRead(fd: SOCKET_FD, rsource: DispatchSourceRead) {
        if state == .connecting {
            checkConnecting(fd: fd)
        } else {
            let bytesAvailable = rsource.data
            if bytesAvailable > 0 {
                onRead()
            } else {
                onClose()
            }
        }
    }
    
    override internal func processWrite(fd: SOCKET_FD, wsource: DispatchSourceWrite) {
        if state == .connecting {
            checkConnecting(fd: fd)
        } else {
            onWrite()
        }
    }
    
    private func checkConnecting(fd: SOCKET_FD) {
        let status = Darwin.connect(self.fd, ssaddr.asSockaddrPointer(), ssaddr.length())
        let err = errno
        if status != 0 && err != EISCONN {
            infoTrace("checkConnecting failed: errno=\(err), " + String(validatingUTF8: strerror(err))!)
            onConnect(.sockError)
        } else {
            let info = getSockName(fd)
            infoTrace("checkConnecting, myaddr=\(info.addr), myport=\(info.port)")
            onConnect(.noError)
        }
    }
    
    fileprivate func onConnect(_ err: KMError) {
        if err == .noError {
            state = .open
            delegate?.onConnect(.noError)
        } else {
            cleanup()
            state = .closed
            delegate?.onConnect(err)
        }
    }
    
    fileprivate func onRead() {
        delegate?.onRead()
    }
    
    fileprivate func onWrite() {
        suspendOnWrite()
        delegate?.onWrite()
    }
    
    fileprivate func onClose() {
        infoTrace("TcpSocket.onClose")
        cleanup()
        state = .closed
        delegate?.onClose()
    }
}

// client socket methods
extension TcpSocket {
    public func bind(_ addr: String, _ port: Int) -> Int {
        infoTrace("TcpSocket.bind, host=\(addr), port=\(port)")
        var status: Int32 = 0
        // Protocol configuration
        var hints = addrinfo(
            ai_flags: AI_PASSIVE,       // Assign the address of my local host to the socket structures
            ai_family: AF_UNSPEC,       // Either IPv4 or IPv6
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        
        var ssaddr = sockaddr_storage()
        if getAddrInfo(addr, port, &hints, &ssaddr) != 0 {
            return -1
        }
        
        let fd = socket(Int32(ssaddr.ss_family), SOCK_STREAM, 0)
        if(fd == -1) {
            errTrace("TcpSocket.bind, socket failed: " + String(validatingUTF8: strerror(errno))!)
            return -1
        }
        status = Darwin.bind(fd, ssaddr.asSockaddrPointer(), ssaddr.length())
        if status < 0 {
            errTrace("TcpSocket.bind, failed: " + String(validatingUTF8: strerror(errno))!)
            return -1
        }
        self.fd = fd
        return Int(status)
    }
    
    public func connect(_ addr: String, _ port: Int) -> Int {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        
        if getAddrInfo(addr, port, &hints, &ssaddr) != 0 {
            errTrace("connect, failed to get addr info, host=\(addr)")
            return -1
        }
        let info = getNameInfo(&ssaddr)
        infoTrace("connect, host=\(addr), ip=\(info.addr), port=\(port)")
        
        if self.fd == kInvalidSocket {
            let fd = socket(Int32(ssaddr.ss_family), SOCK_STREAM, 0)
            if(fd == -1) {
                errTrace("socket failed: " + String(validatingUTF8: strerror(errno))!)
                return -1
            }
            self.fd = fd
        }
        if !initWithFd(self.fd) {
            return -1
        }
        state = .connecting
        var status = Darwin.connect(self.fd, ssaddr.asSockaddrPointer(), ssaddr.length())
        if status == -1 {
            if wouldBlock(errno) {
                status = 0
            } else {
                errTrace("connect failed: " + String(validatingUTF8: strerror(errno))!)
            }
        } else {
            let info = getSockName(self.fd)
            infoTrace("connect, myaddr=\(info.addr), myport=\(info.port)")
        }
        return Int(status)
    }
}

// server socket methods
extension TcpSocket {
    public func attachFd(_ fd: Int32) -> Int {
        if !initWithFd(fd) {
            return -1
        }
        state = .open
        return 0
    }
}

// read methods
extension TcpSocket {
    public func read<T>(_ data: UnsafeMutablePointer<T>, _ len: Int) -> Int {
        if state != .open || fd == kInvalidSocket {
            return 0
        }

        var ret = Darwin.read(fd, data, len * MemoryLayout<T>.size)
        if ret == 0 {
            infoTrace("TcpSocket.read, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("TcpSocket.read, failed, err=\(errno)")
            }
        }
        return ret
    }
    
    public func read<T>(_ data: [T]) -> Int {
        var data = data
        if state != .open {
            return 0
        }
        let dlen = data.count * MemoryLayout<T>.size
        var ret = 0
        ret = data.withUnsafeMutableBufferPointer {
            let ptr = $0.baseAddress
            return self.read(ptr!, dlen)
        }
        return ret
    }
}

// write methods
extension TcpSocket {
    public func write(_ str: String) -> Int {
        if state != .open {
            return 0
        }
        var ret = 0
        ret = self.write(UnsafePointer<UInt8>(str), str.characters.count)
        /*str.withCString { (cstr: UnsafePointer<Int8>) -> Void in
         let len = Int(strlen(cstr))
         if len > 0 {
         cstr.withMemoryRebound(to: UnsafePointer<UInt8>.self, capacity: len) {
         ret = self.write($0, len)
         }
         }
         }*/
        return ret
    }
    
    public func write<T>(_ data: [T]) -> Int {
        if state != .open {
            return 0
        }
        let wlen = data.count * MemoryLayout<T>.size
        return self.write(data, wlen)
    }
    
    public func write<T>(_ data: UnsafePointer<T>, _ len: Int) -> Int {
        if state != .open || fd == kInvalidSocket {
            return 0
        }
        
        let wlen = len * MemoryLayout<T>.size
        var ret = Darwin.write(fd, data, wlen)
        if ret == 0 {
            infoTrace("TcpSocket.write, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("TcpSocket.write, failed, err=\(errno)")
            }
        }
        if ret < wlen {
            resumeOnWrite()
        }
        return ret
    }
    
    public func writev(_ iovs: [iovec]) -> Int {
        if state != .open || fd == kInvalidSocket {
            return 0
        }
        
        var wlen = 0
        for i in 0..<iovs.count {
            wlen += iovs[i].iov_len
        }
        var ret = Darwin.writev(fd, iovs, Int32(iovs.count))
        if ret == 0 {
            infoTrace("TcpSocket.write, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("TcpSocket.writev, failed, err=\(errno)")
            }
        }
        if ret < wlen {
            resumeOnWrite()
        }
        return ret
    }
}
