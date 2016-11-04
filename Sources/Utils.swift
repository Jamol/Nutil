//
//  Utils.swift
//  Nutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

func setNonblocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    guard fcntl(fd, F_SETFL, flags | O_NONBLOCK | O_ASYNC) != -1 else {
        let errorNumber = errno
        print("setNonblocking failed, errno: \(errorNumber) \(strerror(errorNumber))")
        return
    }
}

func getAddrInfo(_ addr: String, _ port: Int, _ hints: UnsafePointer<addrinfo>, _ ssaddr: UnsafeMutablePointer<sockaddr_storage>) -> Int {
    // For the result from the getaddrinfo
    var servinfo: UnsafeMutablePointer<addrinfo>? = nil
    // Get the info we need to create our socket descriptor
    let status = getaddrinfo(addr, String(port), hints, &servinfo)
    if status != 0 {
        //warnTrace("getAddrInfo, failed: err=\(errno), " + String(validatingUTF8: strerror(errno))!)
        warnTrace("getAddrInfo, failed: status=\(status), " + String(validatingUTF8: gai_strerror(status))!)
    }
    if servinfo != nil {
        memcpy(ssaddr, servinfo!.pointee.ai_addr, Int(servinfo!.pointee.ai_addrlen))
        freeaddrinfo(servinfo)
    }
    return Int(status)
}

func getNameInfo(_ ssaddr: UnsafePointer<sockaddr_storage>) -> (addr: String, port: Int) {
    let sslen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let len = Int(INET6_ADDRSTRLEN) + 2
    let addr = [CChar](repeating: 0, count: len)
    let port = [CChar](repeating: 0, count: 16)
    let status = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return getnameinfo($0, sslen, UnsafeMutablePointer<Int8>(mutating: addr), socklen_t(len),     UnsafeMutablePointer<Int8>(mutating: port), 16, NI_NUMERICHOST | NI_NUMERICSERV)
    }
    if status != 0 {
        warnTrace("getNameInfo, failed: status=\(status), " + String(validatingUTF8: gai_strerror(status))!)
        return ("", 0)
    }
    return (String(cString: addr), Int(String(cString: port))!)
}

func getSockName(_ fd: Int32) -> (addr: String, port: Int) {
    var ssaddr = sockaddr_storage()
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let psa = ssaddr.asSockaddrPointer()
    let status = getsockname(fd, psa, &ssalen)
    if status != 0 {
        return ("", 0)
    }
    return getNameInfo(&ssaddr)
}

func getPeerName(_ fd: Int32) -> (addr: String, port: Int) {
    var ssaddr = sockaddr_storage()
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let psa = ssaddr.asSockaddrPointer()
    let status = getpeername(fd, psa, &ssalen)
    if status != 0 {
        return ("", 0)
    }
    return getNameInfo(&ssaddr)
}

extension sockaddr_storage {
    mutating func asSockaddrPointer() -> UnsafeMutablePointer<sockaddr> {
        let praw = UnsafeMutableRawPointer(&self)
        return praw.assumingMemoryBound(to: sockaddr.self)
    }
    
    func length() -> socklen_t {
        if Int32(self.ss_family) == AF_INET {
            return socklen_t(MemoryLayout<sockaddr_in>.size)
        } else if Int32(self.ss_family) == AF_INET6 {
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            return socklen_t(MemoryLayout<sockaddr_storage>.size)
        }
    }
}

func bind(_ fd: Int32, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int32 {
    let ssalen = ssaddr.pointee.length()
    let status = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.bind(fd, $0, ssalen)
    }
    return status
}

func connect(_ fd: Int32, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int32 {
    let ssalen = ssaddr.pointee.length()
    let status = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.connect(fd, $0, ssalen)
    }
    return status
}

func accept(_ fd: Int32, _ ssaddr: UnsafeMutablePointer<sockaddr_storage>) -> Int32 {
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let s = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.accept(fd, $0, &ssalen)
    }
    return s
}

func recvfrom(_ fd: Int32, _ data: UnsafeMutableRawPointer, _ len: Int, _ ssaddr: UnsafeMutablePointer<sockaddr_storage>) -> Int {
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ret = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.recvfrom(fd, data, len, 0, $0, &ssalen)
    }
    return ret
}

func sendto(_ fd: Int32, _ data: UnsafeRawPointer, _ len: Int, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int {
    let ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ret = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.sendto(fd, data, len, 0, $0, ssalen)
    }
    return ret
}
