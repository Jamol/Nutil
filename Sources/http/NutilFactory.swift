//
//  NutilFactory.swift
//  Nutil
//
//  Created by Jamol Bao on 12/20/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public protocol HttpRequest {
    func addHeader(name: String, value: String)
    func addHeader(name: String, value: Int)
    func sendRequest(method: String, url: String) -> KMError
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int
    func sendString(_ str: String) -> Int
    func reset()
    func close()
    
    func getStatusCode() -> Int
    func getHeader(name: String) -> String?
    
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onHeaderComplete(cb: @escaping () -> Void) -> Self
    @discardableResult func onRequestComplete(cb: @escaping () -> Void) -> Self
    @discardableResult func onError(cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(cb: @escaping () -> Void) -> Self
}

public protocol HttpResponse {
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError
    func addHeader(name: String, value: String)
    func addHeader(name: String, value: Int)
    func sendResponse(statusCode: Int, desc: String) -> KMError
    func sendData(_ data: UnsafeRawPointer?, _ len: Int) -> Int
    func sendString(_ str: String) -> Int
    func reset()
    func close()
    
    func getMethod() -> String
    func getUrl() -> String
    func getPath() -> String
    func getHeader(name: String) -> String?
    func getParam(name: String) -> String?
    
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onHeaderComplete(cb: @escaping () -> Void) -> Self
    @discardableResult func onRequestComplete(cb: @escaping () -> Void) -> Self
    @discardableResult func onResponseComplete(cb: @escaping () -> Void) -> Self
    @discardableResult func onError(cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(cb: @escaping () -> Void) -> Self
}

public protocol WebSocket {
    func connect(ws_url: String, cb: @escaping (KMError) -> Void) -> KMError
    func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError
    func sendData(_ data: UnsafeRawPointer, _ len: Int) -> Int
    func close()
    
    @discardableResult func onData(cb: @escaping (UnsafeMutableRawPointer, Int) -> Void) -> Self
    @discardableResult func onError(cb: @escaping (KMError) -> Void) -> Self
    @discardableResult func onSend(cb: @escaping () -> Void) -> Self
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
