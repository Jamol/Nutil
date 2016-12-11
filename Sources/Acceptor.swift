//
//  Acceptor.swift
//  Nutil
//
//  Created by Jamol Bao on 8/5/15.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation
import Darwin

public protocol AcceptDelegate {
    func onAccept(_ fd: Int32, _ ip: String, _ port: Int)
}

public class Acceptor {
    private var fd_: SOCKET_FD = -1
    private var stop_ = false
    private var queue_: DispatchQueue? = nil // serial queue
    private var source_: DispatchSourceRead? = nil
    public var delegate: AcceptDelegate? = nil
    
    public init () {
        
    }
    
    public init (queue: DispatchQueue?) {
        self.queue_ = queue
    }
    
    public func listen(_ host: String, _ port: Int) -> Bool {
        var status: Int32 = 0
        // Protocol configuration
        var hints = addrinfo(
            ai_flags: AI_PASSIVE,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var ssaddr = sockaddr_storage()
        if getAddrInfo(host, port, &hints, &ssaddr) != 0 {
            return false
        }
        
        let fd = socket(Int32(ssaddr.ss_family), SOCK_STREAM, 0)
        infoTrace("Acceptor.listen, fd=\(fd)")
        if(fd == -1) {
            return false
        }
        setNonblocking(fd)
        var val: Int32 = 1
        status  = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val,socklen_t(MemoryLayout<Int32>.size))
        status = Darwin.bind(fd, ssaddr.asSockaddrPointer(), ssaddr.length())
        if status != 0 {
            errTrace("Acceptor.listen, bind failed: " + String(validatingUTF8: strerror(errno))!)
            return false
        }
        status = Darwin.listen(fd, 5)
        if status != 0 {
            errTrace("Acceptor.listen, failed to listen")
            return false
        }
        
        self.fd_ = fd
        
        if queue_ == nil {
            queue_ = DispatchQueue.global(qos: DispatchQoS.QoSClass.default)
            if queue_ == nil {
                errTrace("Acceptor.listen, failed to create dispatch queue")
                return false
            }
        }
        source_ = DispatchSource.makeReadSource(fileDescriptor: fd_, queue: queue_)
        if let source = source_ {
            source.setEventHandler {
                self.onAccept()
            }
            source.setCancelHandler {
                if self.fd_ != -1 {
                    let _ = Darwin.close(self.fd_)
                    self.fd_ = -1
                }
            }
            source.resume()
        } else {
            errTrace("Acceptor.listen, failed to create dispatch source")
            return false
        }
    
        return true
    }
    
    public func stop() {
        infoTrace("Acceptor.stop")
        stop_ = true
        if let source = source_ {
            source.cancel()
            source_ = nil
        }
        if fd_ != -1 {
            let _ = Darwin.close(fd_)
            fd_ = -1
        }
        queue_ = nil
    }
    
    private func onAccept() {
        //var ss_addr = UnsafeMutablePointer<sockaddr_storage>.alloc(1)
        var ssaddr = sockaddr_storage()
        repeat {
            var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let s = Darwin.accept(fd_, ssaddr.asSockaddrPointer(), &ssalen)
            if s != -1 {
                let info = getNameInfo(&ssaddr)
                infoTrace("Acceptor.onAccept, fd=\(s), addr=\(info.addr), port=\(info.port)")
                delegate?.onAccept(s, info.addr, info.port)
            } else {
                if errno != EWOULDBLOCK && !self.stop_ {
                    errTrace("Acceptor.onAccept, accept failed, err=\(errno)")
                }
                break
            }
        } while (!self.stop_)
    }
}
