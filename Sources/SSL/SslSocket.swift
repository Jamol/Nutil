//
//  SslSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 11/4/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public enum SslFlag: UInt32 {
    case none = 0
    case sslDefault         = 0x01
    case allowExpiredCert   = 0x02
    case allowInvalidCertCN = 0x04
    case allowExpiredRoot   = 0x08
    case allowAnyRoot       = 0x10
    case allowRevokedCert   = 0x20
}

public class SslSocket {
    fileprivate let sslHandler = SslHandler()
    fileprivate var tcpSocket: TcpSocket!
    fileprivate var alpnProtos: AlpnProtos? = nil
    fileprivate var serverName = ""
    fileprivate var sslFlags: UInt32 = 0
    
    fileprivate var cbConnect: ErrorCallback?
    fileprivate var cbRead: EventCallback?
    fileprivate var cbWrite: EventCallback?
    fileprivate var cbClose: EventCallback?
    
    public init() {
        tcpSocket = TcpSocket()
        tcpSocket
            .onConnect(onConnect)
            .onRead(onRead)
            .onWrite(onWrite)
            .onClose(onClose)
    }
    
    public init (queue: DispatchQueue?) {
        tcpSocket = TcpSocket(queue: queue)
        tcpSocket
            .onConnect(onConnect)
            .onRead(onRead)
            .onWrite(onWrite)
            .onClose(onClose)
    }
    
    public func bind(_ addr: String, _ port: Int) -> KMError {
        return tcpSocket.bind(addr, port)
    }
    
    public func connect(_ addr: String, _ port: Int) -> KMError {
        return tcpSocket.connect(addr, port)
    }
    
    public func attachFd(_ fd: Int32) -> KMError {
        return tcpSocket.attachFd(fd)
    }
    
    public func close() {
        cleanup()
    }
    
    func cleanup() {
        sslHandler.close()
        tcpSocket.close()
    }
}

// read methods
extension SslSocket {
    public func read<T>(_ data: UnsafeMutablePointer<T>, _ len: Int) -> Int {
        let ret = sslHandler.receive(data: data, len: len)
        if ret < 0 {
            cleanup()
        }
        return ret
    }
}

// write methods
extension SslSocket {
    public func write(_ str: String) -> Int {
        return self.write(UnsafePointer<Int8>(str), str.utf8.count)
    }
    
    public func write<T>(_ data: [T]) -> Int {
        let wlen = data.count * MemoryLayout<T>.size
        return self.write(data, wlen)
    }
    
    public func write<T>(_ data: UnsafePointer<T>, _ len: Int) -> Int {
        let ret = sslHandler.send(data: data, len: len)
        if ret < 0 {
            cleanup()
        }
        return ret
    }
    
    public func writev(_ iovs: [iovec]) -> Int {
        let ret = sslHandler.send(iovs: iovs)
        if ret < 0 {
            cleanup()
        }
        return ret
    }
}

extension SslSocket {
    func onConnect(err: KMError) {
        if err == .noError {
            let err = startSslHandshake(.client)
            if err == .noError && sslHandler.getState() == .handshake {
                return // continue to SSL handshake
            }
        } else {
            cleanup()
        }
        cbConnect?(err)
    }
    func onRead() {
        if sslHandler.getState() == .handshake {
            _ = checkSslState()
        } else {
            cbRead?()
        }
    }
    func onWrite() {
        if sslHandler.getState() == .handshake {
            _ = checkSslState()
        } else {
            cbWrite?()
        }
    }
    func onClose() {
        cleanup()
        cbClose?()
    }
    
    func checkSslState() -> Bool {
        if sslHandler.getState() == .handshake {
            let ssl_state = sslHandler.doSslHandshake()
            if ssl_state == .error {
                cbConnect?(.sslError)
                return false
            } else if ssl_state == .handshake {
                return false
            } else {
                cbConnect?(.noError)
            }
        }
        return true
    }
}

extension SslSocket {
    func setSslFlags(_ flags: UInt32) {
        sslFlags = flags
    }
    
    func getSslFlags() -> UInt32 {
        return sslFlags
    }
    
    func sslEnabled() -> Bool {
        return sslFlags != SslFlag.none.rawValue
    }
    
    func setAlpnProtocols(_ alpn: AlpnProtos) {
        alpnProtos = alpn
    }
    
    func getAlpnSelected() -> String? {
        return sslHandler.getAlpnSelected()
    }
    
    func setSslServerName(_ name: String) {
        self.serverName = name
    }
}

extension SslSocket {
    func startSslHandshake(_ role: SslRole) -> KMError {
        infoTrace("startSslHandshake, role=\(role), fd=\(tcpSocket.fd), state=\(tcpSocket.state)")
        sslHandler.close()
        try? sslHandler.attachFd(fd: tcpSocket.fd, role: role)
        if (role == .client) {
            if let alpn = alpnProtos {
                if !sslHandler.setAlpnProtocols(alpn: alpn) {
                    warnTrace("startSslHandshake, failed to set alpn: \(alpn)")
                }
            }
            if !serverName.isEmpty {
                sslHandler.setServerName(name: serverName)
            }
        }
        
        let ssl_state = sslHandler.doSslHandshake()
        if(ssl_state == .error) {
            return .sslError
        }
        return .noError
    }
}

extension SslSocket {
    func sync(_ block: ((Void) -> Void)) {
        tcpSocket.sync(block)
    }
    
    func async(_ block: @escaping ((Void) -> Void)) {
        tcpSocket.async(block)
    }
}

extension SslSocket {
    @discardableResult public func onConnect(_ cb: @escaping (KMError) -> Void) -> Self {
        cbConnect = cb
        return self
    }
    
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
