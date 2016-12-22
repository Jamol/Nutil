//
//  HttpUtils.swift
//  Nutil
//
//  Created by Jamol Bao on 12/11/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

let kDefauleUserAgent = "kuma 1.0"
let kContentLength = "Content-Length"
let kTransferEncoding = "Transfer-Encoding"
let kUpgrade = "Upgrade"
let kConnection = "Connection"

let kWebScoket = "WebSocket"

typealias DataCallback = (UnsafeMutableRawPointer, Int) -> Void
typealias ErrorCallback = (KMError) -> Void
typealias EventCallback = () -> Void

func generateSecAcceptValue(_ secWsKey: String) -> String {
    let secAcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let kSHA1GigestSize = 20
    if secWsKey.isEmpty {
        return ""
    }
    var str = secWsKey + secAcceptGuid
    var shaResult = Array<UInt8>(repeating: 0, count: kSHA1GigestSize)
    _ = shaResult.withUnsafeMutableBufferPointer {
        SHA1(str, str.utf8.count, $0.baseAddress)
    }
    let dd = Data(bytes: shaResult)
    str = dd.base64EncodedString()
    return str
}
