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

typealias DataCallback = (UnsafeMutableRawPointer, Int) -> Void
typealias EventCallback = () -> Void
