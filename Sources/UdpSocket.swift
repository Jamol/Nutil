//
//  UdpSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation
import Darwin

public class UdpSocket : Socket
{
    enum SocketState {
        case idle
        case open
        case closed
    }
    fileprivate var state: SocketState = .idle
    
    fileprivate var cbRead: EventCallback?
    fileprivate var cbWrite: EventCallback?
    fileprivate var cbClose: EventCallback?
    
    public init () {
        super.init(queue: nil)
    }
    
    public override init (queue: DispatchQueue?) {
        super.init(queue: queue)
    }
    
    deinit {

    }
    
    func isOpen() -> Bool {
        return state == .open
    }
    
    public func bind(_ addr: String, _ port: Int) -> KMError {
        infoTrace("UdpSocket.bind, host=\(addr), port=\(port)")
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
            return .invalidParam
        }
        
        let fd = socket(Int32(ssaddr.ss_family), SOCK_DGRAM, 0)
        if(fd == -1) {
            errTrace("UdpSocket.bind, socket failed: " + String(validatingUTF8: strerror(errno))!)
            return .sockError
        }
        status = Darwin.bind(fd, ssaddr.asSockaddrPointer(), ssaddr.length())
        if status < 0 {
            errTrace("UdpSocket.bind, bind failed: " + String(validatingUTF8: strerror(errno))!)
            return .sockError
        }
        if !initWithFd(fd) {
            return .failed
        }
        state = .open
        return .noError
    }

    override internal func processRead(fd: SOCKET_FD, rsource: DispatchSourceRead) {
        let bytesAvailable = rsource.data
        if bytesAvailable > 0 {
            onRead()
        } else {
            onClose()
        }
    }
    
    override internal func processWrite(fd: SOCKET_FD, wsource: DispatchSourceWrite) {
        onWrite()
    }
    
    fileprivate func onRead() {
        cbRead?()
    }
    
    fileprivate func onWrite() {
        suspendOnWrite()
        cbWrite?()
    }
    
    fileprivate func onClose() {
        infoTrace("UdpSocket.onClose")
        cleanup()
        state = .closed
        cbClose?()
    }
}

// read methods
extension UdpSocket {
    public func read<T>(_ data: UnsafeMutablePointer<T>, _ len: Int) -> (ret: Int, addr: String, port: Int) {
        if state != .open {
            return (0, "", 0)
        }
        if fd == kInvalidSocket {
            return (0, "", 0)
        }
        let dlen = len * MemoryLayout<T>.size
        var ssaddr = sockaddr_storage()
        var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var ret = Darwin.recvfrom(fd, data, dlen, 0, ssaddr.asSockaddrPointer(), &ssalen)
        if ret == 0 {
            infoTrace("UdpSocket.read, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("UdpSocket.read, failed, err=\(errno)")
            }
        }
        let info = getNameInfo(&ssaddr)
        return (ret, info.addr, info.port)
    }
}

// write methods
extension UdpSocket {
    public func write(_ str: String, _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        let ret = str.withCString {
            return self.write($0, str.utf8.count, addr, port)
        }
        return ret
    }
    
    public func write<T>(_ data: [T], _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        let wlen = data.count * MemoryLayout<T>.size
        return self.write(data, wlen, addr, port)
    }
    
    public func write<T>(_ data: UnsafePointer<T>, _ len: Int, _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        if fd == kInvalidSocket {
            return 0
        }
        let dlen = len * MemoryLayout<T>.size
        var ssaddr = sockaddr_storage()
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        let status = getAddrInfo(addr, port, &hints, &ssaddr)
        if status != 0 {
            errTrace("UdpSocket.write, invalid address")
            return -1
        }
        var ret = Darwin.sendto(fd, data, dlen, 0, ssaddr.asSockaddrPointer(), ssaddr.length())
        if ret == 0 {
            infoTrace("UdpSocket.write, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("UdpSocket.write, failed, err=\(errno)")
            }
        }
        if ret < dlen {
            resumeOnWrite()
            errTrace("UdpSocket.write, partial written ???")
        }
        return ret
    }
    
    public func writev(_ iovs: [iovec], _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        if fd == kInvalidSocket {
            return 0
        }
        var dlen = 0
        for i in 0..<iovs.count {
            dlen += iovs[i].iov_len
        }
        
        var ssaddr = sockaddr_storage()
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        let status = getAddrInfo(addr, port, &hints, &ssaddr)
        if status != 0 {
            errTrace("UdpSocket.write, invalid address")
            return -1
        }
        
        var mh = msghdr()
        mh.msg_name = UnsafeMutableRawPointer(&ssaddr)
        mh.msg_namelen = ssaddr.length()
        mh.msg_control = nil
        mh.msg_controllen = 0
        mh.msg_flags = 0
        mh.msg_iovlen = Int32(iovs.count)
        
        var iovs = iovs
        var ret = -1
        ret = iovs.withUnsafeMutableBufferPointer {
            mh.msg_iov = $0.baseAddress
            return Darwin.sendmsg(fd, &mh, Int32(0))
        }
        
        if ret == 0 {
            infoTrace("UdpSocket.write, peer closed")
            ret = -1
        } else if ret < 0 {
            if wouldBlock(errno) {
                ret = 0
            } else {
                errTrace("UdpSocket.write, failed, err=\(errno)")
            }
        }
        if ret < dlen {
            resumeOnWrite()
            errTrace("UdpSocket.write, partial written ???")
        }
        return ret
    }
}

extension UdpSocket {
    @discardableResult public func onRead(_ cb: @escaping () -> Void) -> Self {
        cbRead = cb
        return self
    }
    
    @discardableResult public func onWrite(_ cb: @escaping () -> Void) -> Self {
        cbWrite = cb
        return self
    }
    
    @discardableResult public func onClose(_ cb: @escaping () -> Void) -> Self {
        cbClose = cb
        return self
    }
}
