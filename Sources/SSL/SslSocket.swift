//
//  SslSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 11/4/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public typealias SslDelegate = TcpDelegate

public class SslSocket {
    fileprivate let sslHandler = SslHandler()
    fileprivate var tcpSocket: TcpSocket!
    fileprivate var alpnProtos: AlpnProtos? = nil
    fileprivate var serverName = ""
    public var delegate: SslDelegate?
    
    public init() {
        tcpSocket = TcpSocket()
        tcpSocket.delegate = self
    }
    
    public init (queue: DispatchQueue?) {
        tcpSocket = TcpSocket(queue: queue)
        tcpSocket.delegate = self
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

extension SslSocket: TcpDelegate {
    public func onConnect(err: KMError) {
        if err == .noError {
            let err = startSslHandshake(role: .client)
            if err == .noError && sslHandler.getState() == .handshake {
                return // continue to SSL handshake
            }
        } else {
            cleanup()
        }
        delegate?.onConnect(err: err)
    }
    public func onRead() {
        if sslHandler.getState() == .handshake {
            _ = checkSslState()
        } else {
            delegate?.onRead()
        }
    }
    public func onWrite() {
        if sslHandler.getState() == .handshake {
            _ = checkSslState()
        } else {
            delegate?.onWrite()
        }
    }
    public func onClose() {
        cleanup()
        delegate?.onClose()
    }
    
    func checkSslState() -> Bool {
        if sslHandler.getState() == .handshake {
            let ssl_state = sslHandler.doSslHandshake()
            if ssl_state == .error {
                delegate?.onConnect(err: .sslError)
                return false
            } else if ssl_state == .handshake {
                return false
            } else {
                delegate?.onConnect(err: .noError)
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
