//
//  HttpHeader.swift
//  Nutil
//
//  Created by Jamol Bao on 1/24/17.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

class HttpHeader {
    var headers: [String: String] = [:]
    var contentLength: Int?
    var isChunked = false
    fileprivate var hasBody_ = false
    fileprivate var isHttp2 = false
    
    var hasBody: Bool {
        return hasBody_
    }
    
    func addHeader(_ name: String, _ value: String) {
        if !name.isEmpty {
            headers[name] = value
        }
    }
    
    func addHeader(_ name: String, _ value: Int) {
        addHeader(name, String(value))
    }
    
    func hasHeader(_ name: String) -> Bool {
        return headers[name] != nil
    }
    
    fileprivate func processHeader() {
        var val = headers[kContentLength]
        if let v = val {
            contentLength = Int(v)
        } else {
            contentLength = nil
        }
        val = headers[kTransferEncoding]
        if let v = val {
            isChunked = v.caseInsensitiveCompare("chunked") == .orderedSame
        } else {
            isChunked = false
        }
        
        hasBody_ = isChunked || (contentLength != nil && contentLength! > 0)
    }
    
    func buildHeader(_ method: String, _ url: String, _ ver: String) -> String {
        processHeader()
        var req = method + " " + url + " " + ver
        req += "\r\n"
        for kv in headers {
            req += kv.key + ": " + kv.value + "\r\n"
        }
        req += "\r\n"
        return req
    }
    
    func buildHeader(_ statusCode: Int, _ desc: String, _ ver: String) -> String {
        processHeader()
        var rsp = "\(ver) \(statusCode)"
        if (!desc.isEmpty) {
            rsp += " " + desc
        }
        rsp += "\r\n"
        for kv in headers {
            rsp += kv.key + ": " + kv.value + "\r\n"
        }
        rsp += "\r\n"
        hasBody_ = hasBody_ || !((100 <= statusCode && statusCode <= 199) ||
            204 == statusCode || 304 == statusCode)
        return rsp
    }
    
    func reset() {
        headers.removeAll()
        contentLength = nil
        isChunked = false
        hasBody_ = false
    }
}
