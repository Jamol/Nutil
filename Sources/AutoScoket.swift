//
//  AutoScoket.swift
//  Nutil
//
//  Created by Jamol Bao on 12/22/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class AutoScoket {
    fileprivate var tcp: TcpSocket?
    fileprivate var ssl: SslSocket?
    
    fileprivate var cbConnect: ErrorCallback?
    fileprivate var cbRead: EventCallback?
    fileprivate var cbWrite: EventCallback?
    fileprivate var cbClose: EventCallback?
    
    fileprivate func initTcpSocket() {
        if tcp != nil {
            return
        }
        tcp = TcpSocket()
        tcp!
            .onConnect { err in
                self.cbConnect?(err)
            }
            .onRead {
                self.cbRead?()
            }
            .onWrite {
                self.cbWrite?()
            }
            .onClose {
                self.cbClose?()
        }
    }
    
    fileprivate func initSslSocket() {
        if ssl != nil {
            return
        }
        ssl = SslSocket()
        ssl!
            .onConnect { err in
                self.cbConnect?(err)
            }
            .onRead {
                self.cbRead?()
            }
            .onWrite {
                self.cbWrite?()
            }
            .onClose {
                self.cbClose?()
        }
    }
    
    func bind(_ addr: String, _ port: Int) -> KMError {
        if let s = ssl {
            return s.bind(addr, port)
        }
        initTcpSocket()
        return tcp!.bind(addr, port)
    }
    
    func connect(_ addr: String, _ port: Int) -> KMError {
        if let s = ssl {
            return s.connect(addr, port)
        }
        initTcpSocket()
        return tcp!.connect(addr, port)
    }
    
    func attachFd(_ fd: Int32) -> KMError {
        if let s = ssl {
            return s.attachFd(fd)
        }
        initTcpSocket()
        return tcp!.attachFd(fd)
    }
    
    func close() {
        if let ssl = ssl {
            ssl.close()
        }
        if let tcp = tcp {
            tcp.close()
        }
    }
}

extension AutoScoket {
    func read<T>(_ data: UnsafeMutablePointer<T>, _ len: Int) -> Int {
        if let ssl = ssl {
            return ssl.read(data, len)
        }
        if let tcp = tcp {
            return tcp.read(data, len)
        }
        return -1
    }
    
    func write(_ str: String) -> Int {
        if let ssl = ssl {
            return ssl.write(str)
        }
        if let tcp = tcp {
            return tcp.write(str)
        }
        return -1
    }
    
    func write<T>(_ data: [T]) -> Int {
        if let ssl = ssl {
            return ssl.write(data)
        }
        if let tcp = tcp {
            return tcp.write(data)
        }
        return -1
    }
    
    func write<T>(_ data: UnsafePointer<T>, _ len: Int) -> Int {
        if let ssl = ssl {
            return ssl.write(data, len)
        }
        if let tcp = tcp {
            return tcp.write(data, len)
        }
        return -1
    }
    
    func writev(_ iovs: [iovec]) -> Int {
        if let ssl = ssl {
            return ssl.writev(iovs)
        }
        if let tcp = tcp {
            return tcp.writev(iovs)
        }
        return -1
    }
}

extension AutoScoket {
    func setSslFlags(flags: UInt32) {
        if flags != SslFlag.none.rawValue {
            initSslSocket()
            ssl!.setSslFlags(flags: flags)
        }
    }
    
    func getSslFlags() -> UInt32 {
        if let s = ssl {
            return s.getSslFlags()
        }
        return SslFlag.none.rawValue
    }
    
    func sslEnabled() -> Bool {
        return ssl != nil
    }
    
    func setAlpnProtocols(alpn: AlpnProtos) {
        initSslSocket()
        ssl!.setAlpnProtocols(alpn: alpn)
    }
    
    func getAlpnSelected() -> String? {
        if let ssl = ssl {
            return ssl.getAlpnSelected()
        }
        return nil
    }
    
    func setServerName(name: String) {
        initSslSocket()
        ssl!.setSslServerName(name: name)
    }
}

extension AutoScoket {
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

extension AutoScoket {
    func sync(_ block: ((Void) -> Void)) {
        if let ssl = ssl {
            ssl.sync(block)
        }
        if let tcp = tcp {
            tcp.sync(block)
        }
    }
    
    func async(_ block: @escaping ((Void) -> Void)) {
        if let ssl = ssl {
            ssl.async(block)
        }
        if let tcp = tcp {
            tcp.async(block)
        }
    }
}
