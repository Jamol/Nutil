//
//  H2ConnectionMgr.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

final class H2ConnectionMgr {
    fileprivate var connMap: [String : H2Connection] = [:]
    
    private init() {
    }
    
    func addConnection(_ key: String, _ conn: H2Connection) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        connMap[key] = conn
    }
    
    func getConnection(_ key: String) -> H2Connection? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return connMap[key]
    }
    
    func getConnection(_ host: String, _ port: Int, _ sslFlags: UInt32) -> H2Connection? {
        var ss_addr = sockaddr_storage()
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        
        if getAddrInfo(host, port, &hints, &ss_addr) != 0 {
            errTrace("getConnection, failed to get addr info, host=\(host)")
            return nil
        }
        let info = getNameInfo(&ss_addr)
        let connKey = "\(info.addr):\(info.port)"
        
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        var conn = connMap[connKey]
        if conn != nil {
            return conn
        }
        conn = H2Connection()
        conn!.setConnectionKey(connKey)
        conn!.setSslFlags(sslFlags)
        if conn!.connect(host, port) != .noError {
            return nil
        }
        connMap[connKey] = conn!
        return conn
    }
    
    func removeConnection(_ key: String) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        connMap.removeValue(forKey: key)
    }
    
    class func getRequestConnMgr(_ secure: Bool) -> H2ConnectionMgr {
        if secure {
            return sharedSecure
        } else {
            return sharedNormal
        }
    }
    
    static let sharedNormal: H2ConnectionMgr = H2ConnectionMgr()
    static let sharedSecure: H2ConnectionMgr = H2ConnectionMgr()
}
