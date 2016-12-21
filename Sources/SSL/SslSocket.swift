//
//  SslSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 11/4/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public class SslSocket {
    fileprivate let sslHandler = SslHandler()
    fileprivate var tcpSocket: TcpSocket!
    fileprivate var alpnProtos: AlpnProtos? = nil
    fileprivate var serverName = ""
    
    fileprivate var cbConnect: ((KMError) -> Void)?
    fileprivate var cbRead: (() -> Void)?
    fileprivate var cbWrite: (() -> Void)?
    fileprivate var cbClose: (() -> Void)?
    
    public init() {
        tcpSocket = TcpSocket()
        tcpSocket
            .onConnect(cb: onConnect)
            .onRead(cb: onRead)
            .onWrite(cb: onWrite)
            .onClose(cb: onClose)
    }
    
    public init (queue: DispatchQueue?) {
        tcpSocket = TcpSocket(queue: queue)
        tcpSocket
            .onConnect(cb: onConnect)
            .onRead(cb: onRead)
            .onWrite(cb: onWrite)
            .onClose(cb: onClose)
    }
    
    public func bind(_ addr: String, _ port: Int) -> Int {
        return tcpSocket.bind(addr, port)
    }
    
    public func connect(_ addr: String, _ port: Int) -> Int {
        return tcpSocket.connect(addr, port)
    }
    
    public func attachFd(_ fd: Int32) -> Int {
        return tcpSocket.attachFd(fd)
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
    
    public func read<T>(_ data: [T]) -> Int {
        var data = data
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
            let err = startSslHandshake(role: .client)
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
    func startSslHandshake(role: SslRole) -> KMError {
        infoTrace("startSslHandshake, role=\(role), fd=\(tcpSocket.fd), state=\(tcpSocket.state)")
        sslHandler.close()
        try? sslHandler.attachFd(fd: tcpSocket.fd, role: role)
        if (role == .client) {
            if let alpn = alpnProtos {
                sslHandler.setAlpnProtocols(alpn: alpn)
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
    @discardableResult public func onConnect(cb: @escaping (KMError) -> Void) -> Self {
        cbConnect = cb
        return self
    }
    
    @discardableResult public func onRead(cb: @escaping () -> Void) -> Self {
        cbRead = cb
        return self
    }
    
    @discardableResult public func onWrite(cb: @escaping () -> Void) -> Self {
        cbWrite = cb
        return self
    }
    
    @discardableResult public func onClose(cb: @escaping () -> Void) -> Self {
        cbClose = cb
        return self
    }
}
