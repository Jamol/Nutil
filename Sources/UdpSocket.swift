//
//  UdpSocket.swift
//  tutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 jamol. All rights reserved.
//

import Foundation
import Darwin

public protocol UdpDelegate {
    func onRead()
    func onWrite()
    func onClose()
}

public class UdpSocket : Socket
{
    public var delegate: UdpDelegate? = nil
    
    enum SocketState {
        case idle
        case open
        case closed
    }
    
    fileprivate var state: SocketState = .idle
    
    public init () {
        super.init(dq: nil)
    }
    
    public init (queue: DispatchQueue?) {
        super.init(dq: queue)
    }
    
    deinit {

    }
    
    func isOpen() -> Bool {
        return state == .open
    }
    
    public func bind(_ addr: String, _ port: Int) -> Int {
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
            return -1
        }
        
        let fd = socket(Int32(ssaddr.ss_family), SOCK_DGRAM, 0)
        if(fd == -1) {
            errTrace("UdpSocket.bind, socket failed: " + String(validatingUTF8: strerror(errno))!)
            return -1
        }
        status = Nutil.bind(fd, &ssaddr)
        if status < 0 {
            errTrace("UdpSocket.bind, bind failed: " + String(validatingUTF8: strerror(errno))!)
            return -1
        }
        if !initWithFd(fd) {
            return -1
        }
        state = .open
        return Int(status)
    }

    override internal func processRead(fd: Int32, rsource: DispatchSourceRead) {
        let bytesAvailable = rsource.data
        if bytesAvailable > 0 {
            onRead()
        } else {
            onClose()
        }
    }
    
    override internal func processWrite(fd: Int32, wsource: DispatchSourceWrite) {
        onWrite()
    }
    
    fileprivate func onRead() {
        delegate?.onRead()
    }
    
    fileprivate func onWrite() {
        suspendOnWrite()
        delegate?.onWrite()
    }
    
    fileprivate func onClose() {
        infoTrace("UdpSocket.onClose")
        cleanup()
        state = .closed
        delegate?.onClose()
    }
}

// read methods
extension UdpSocket {
    public func read<T>(_ data: UnsafeMutablePointer<T>, _ len: Int) -> (ret: Int, addr: String, port: Int) {
        if state != .open {
            return (0, "", 0)
        }
        if let fd = self.fd {
            let dlen = len * MemoryLayout<T>.size
            var ssaddr = sockaddr_storage()
            var ret = Nutil.recvfrom(fd, data, dlen, &ssaddr)
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
        return (0, "", 0)
    }
    
    public func read<T>(_ data: [T]) -> (ret: Int, addr: String, port: Int) {
        var data = data
        if state != .open {
            return (0, "", 0)
        }
        let dlen = data.count * MemoryLayout<T>.size
        var ret = (0, "", 0)
        ret = data.withUnsafeMutableBufferPointer {
            let ptr = $0.baseAddress
            return self.read(ptr!, dlen)
        }
        return ret
    }
}

// write methods
extension UdpSocket {
    public func write(_ str: String, _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        var ret = 0
        ret = self.write(UnsafePointer<UInt8>(str), str.characters.count, addr, port)
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
        if let fd = self.fd {
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
            var ret = Nutil.sendto(fd, data, dlen, &ssaddr)
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
        return 0
    }
    
    public func writev(_ ivs: [iovec], _ addr: String, _ port: Int) -> Int {
        if state != .open {
            return 0
        }
        if let fd = self.fd {
            var dlen = 0
            for i in 0..<ivs.count {
                dlen += ivs[i].iov_len
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
            if AF_INET == Int32(ssaddr.ss_family) {
                mh.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
            } else {
                mh.msg_namelen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
            mh.msg_control = nil
            mh.msg_controllen = 0
            mh.msg_flags = 0
            mh.msg_iovlen = Int32(ivs.count)
            
            var ivs = ivs
            var ret = -1
            ret = ivs.withUnsafeMutableBufferPointer {
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
        return 0
    }
}
