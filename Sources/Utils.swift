//
//  Utils.swift
//  Nutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

func setNonblocking(_ fd: SOCKET_FD) {
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

func getSockName(_ fd: SOCKET_FD) -> (addr: String, port: Int) {
    var ssaddr = sockaddr_storage()
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let psa = ssaddr.asSockaddrPointer()
    let status = getsockname(fd, psa, &ssalen)
    if status != 0 {
        return ("", 0)
    }
    return getNameInfo(&ssaddr)
}

func getPeerName(_ fd: SOCKET_FD) -> (addr: String, port: Int) {
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

func bind(_ fd: SOCKET_FD, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int32 {
    let ssalen = ssaddr.pointee.length()
    let status = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.bind(fd, $0, ssalen)
    }
    return status
}

func connect(_ fd: SOCKET_FD, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int32 {
    let ssalen = ssaddr.pointee.length()
    let status = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.connect(fd, $0, ssalen)
    }
    return status
}

func accept(_ fd: SOCKET_FD, _ ssaddr: UnsafeMutablePointer<sockaddr_storage>) -> Int32 {
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let s = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.accept(fd, $0, &ssalen)
    }
    return s
}

func recvfrom(_ fd: SOCKET_FD, _ data: UnsafeMutableRawPointer, _ len: Int, _ ssaddr: UnsafeMutablePointer<sockaddr_storage>) -> Int {
    var ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ret = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.recvfrom(fd, data, len, 0, $0, &ssalen)
    }
    return ret
}

func sendto(_ fd: SOCKET_FD, _ data: UnsafeRawPointer, _ len: Int, _ ssaddr: UnsafePointer<sockaddr_storage>) -> Int {
    let ssalen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ret = ssaddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        return Darwin.sendto(fd, data, len, 0, $0, ssalen)
    }
    return ret
}

fileprivate let number1 = "0123456789".utf8.map { UInt8($0) }
fileprivate let number2 = "abcdef".utf8.map { UInt8($0) }
fileprivate let number3 = "ABCDEF".utf8.map { UInt8($0) }
let kSP = UInt8(ascii: " ")
func hexStringToArray(hexStr: String) -> [UInt8] {
    var bbuf = Array<UInt8>(repeating: 0, count: 256)
    for i in 0..<10 {
        bbuf[Int(number1[i])] = UInt8(i)
    }
    for i in 0..<6 {
        bbuf[Int(number2[i])] = UInt8(i + 10)
        bbuf[Int(number3[i])] = UInt8(i + 10)
    }
    var rbuf: [UInt8] = []
    let slen = hexStr.utf8.count
    hexStr.withCString {
        let ptr = $0
        var i = 0
        while i < slen {
            if UInt8(ptr[i]) == kSP {
                i += 1
                continue
            }
            var u8: UInt8 = 0
            u8 = (bbuf[Int(ptr[i])] << 4) | bbuf[Int(ptr[i + 1])]
            rbuf.append(u8)
            i += 2
        }
    }
    return rbuf
}

// func < for enums
func <<T: RawRepresentable>(a: T, b: T) -> Bool where T.RawValue: Comparable {
    return a.rawValue < b.rawValue
}
