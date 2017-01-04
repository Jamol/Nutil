//
//  NutilAPI.swift
//  Nutil
//
//  Created by Jamol Bao on 12/20/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public protocol HttpRequest {
    func addHeader(_ name: String, _ value: String)
    func addHeader(_ name: String, _ value: Int)
    func sendRequest(_ method: String, _ url: String) -> KMError
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int
    func sendString(_ str: String) -> Int
    func reset()
    func close()
    
    func getStatusCode() -> Int
    func getHeader(_ name: String) -> String?
    
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onHeaderComplete(_ cb: @escaping () -> Void) -> Self
    @discardableResult func onRequestComplete(_ cb: @escaping () -> Void) -> Self
    @discardableResult func onError(_ cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(_ cb: @escaping () -> Void) -> Self
}

public protocol HttpResponse {
    func setSslFlags(_ flags: UInt32)
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError
    func addHeader(_ name: String, _ value: String)
    func addHeader(_ name: String, _ value: Int)
    func sendResponse(_ statusCode: Int, _ desc: String) -> KMError
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int
    func sendString(_ str: String) -> Int
    func reset()
    func close()
    
    func getMethod() -> String
    func getUrl() -> String
    func getPath() -> String
    func getHeader(_ name: String) -> String?
    func getParam(_ name: String) -> String?
    
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onHeaderComplete(_ cb: @escaping () -> Void) -> Self
    @discardableResult func onRequestComplete(_ cb: @escaping () -> Void) -> Self
    @discardableResult func onResponseComplete(_ cb: @escaping () -> Void) -> Self
    @discardableResult func onError(_ cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(_ cb: @escaping () -> Void) -> Self
}

public protocol WebSocket {
    func connect(_ ws_url: String, _ cb: @escaping (KMError) -> Void) -> KMError
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError
    func sendData(_ data: UnsafeRawPointer, _ len: Int) -> Int
    func close()
    
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onError(_ cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(_ cb: @escaping () -> Void) -> Self
}

public class NutilFactory {
    public class func createRequest(version: String) -> HttpRequest? {
        return Http1xRequest(version: version)
    }
    
    public class func createResponse(version: String) -> HttpResponse? {
        return Http1xResponse(version: version)
    }
    
    public class func createWebSocket() -> WebSocket {
        return WebSocketImpl()
    }
}
