//
//  HttpParser.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

let kCR = "\r".utf8.map{ Int8($0) }[0]
let kLF = "\n".utf8.map{ Int8($0) }[0]
let kMaxHttpHeadSize = 10*1024*1024

protocol HttpParserDelegate {
    func onData(data: UnsafeMutableRawPointer, len: Int)
    func onHeaderComplete()
    func onComplete()
    func onError()
}

class HttpParser {
    enum ReadState {
        case line
        case head
        case body
        case done
        case error
    }
    enum ParseState {
        case incomplete
        case success
        case failure
    }
    enum ChunkReadState {
        case size
        case data
        case data_cr
        case data_lf
        case trailer
    }
    
    fileprivate var contentLength:Int?
    fileprivate var totalBytesRead = 0
    fileprivate var readState = ReadState.line
    
    fileprivate var isChunked = false
    fileprivate var chunkState = ChunkReadState.size
    fileprivate var chunkSize = 0
    
    var delegate: HttpParserDelegate?
    
    private var savedString = ""
    
    fileprivate var isPaused = false
    fileprivate var isUpgrade = false
    fileprivate var isRequest = false
    
    fileprivate var method = ""
    fileprivate var urlString = ""
    fileprivate var statusCode = 0
    fileprivate var version = "HTTP/1.1"
    fileprivate var url: URL!
    
    fileprivate var headers = [String: String]()
    
    func reset() {
        readState = .line
        
        isChunked = false
        chunkState = .size
        chunkSize = 0
        
        contentLength = nil
        totalBytesRead = 0
        isPaused = false
        isUpgrade = false
        isRequest = false
        savedString = ""
        
        statusCode = 0
        urlString = ""
        
        headers.removeAll()
    }
    
    func complete() -> Bool {
        return readState == .done
    }
    
    func error() -> Bool {
        return readState == .error
    }
    
    func pause() {
        isPaused = true
    }
    
    func resume() {
        isPaused = false
        if hasBody() && !isUpgrade {
            readState = .body
        } else {
            readState = .done
            onComplete()
        }
    }
    
    func parse(data: UnsafeMutableRawPointer, len: Int) -> Int {
        if readState == .done || readState == .error {
            warnTrace("HttpParser::parse, invalid state: \(readState)")
            return 0
        }
        if readState == .body && !isChunked && contentLength != nil {
            totalBytesRead += len
            delegate?.onData(data: data, len: len)
            return len
        }
        let bytesRead = parseHttp(data: data, len: len)
        if readState == .error {
            delegate?.onError()
        }
        return bytesRead
    }
    
    fileprivate func parseHttp(data: UnsafeMutableRawPointer, len: Int) -> Int {
        var ptr = data.assumingMemoryBound(to: Int8.self)
        var remain = len
        if readState == .line {
            let ret = getLine(data: ptr, len: remain)
            ptr = ptr.advanced(by: ret.bytesRead)
            remain -= ret.bytesRead
            if var line = ret.line {
                if !savedString.isEmpty {
                    line = savedString + line
                    savedString = ""
                }
                if !parseStartLine(line: line) {
                    readState = .error
                    return len - remain
                }
                readState = .head
            } else {
                if !saveData(data: ptr, len: remain) {
                    readState = .error
                    return len - remain
                }
                return len
            }
        }
        if readState == .head {
            repeat {
                let ret = getLine(data: ptr, len: remain)
                ptr = ptr.advanced(by: ret.bytesRead)
                remain -= ret.bytesRead
                if var line = ret.line {
                    if !savedString.isEmpty {
                        line = savedString + line
                        savedString = ""
                    }
                    if line.isEmpty { // empty line, header end
                        onHeaderComplete()
                        if isPaused {
                            return len - remain
                        }
                        if hasBody() && !isUpgrade {
                            readState = .body
                        } else {
                            readState = .done
                            onComplete()
                            return len - remain
                        }
                        break
                    }
                    if !parseHeadLine(line: line) {
                        readState = .error
                        return len - remain
                    }
                } else {
                    if !saveData(data: ptr, len: remain) {
                        readState = .error
                        return len - remain
                    }
                    return len
                }
            } while (true)
        }
        if readState == .body {
            if isChunked {
                return len - remain + parseChunk(data: ptr, len: remain)
            }
            if let clen = contentLength, clen - totalBytesRead <= remain {
                let notifySize = clen - totalBytesRead
                let notifyData = ptr
                ptr = ptr.advanced(by: notifySize)
                remain -= notifySize
                totalBytesRead += notifySize
                readState = .done
                delegate?.onData(data: notifyData, len: notifySize)
                onComplete()
            } else { // need more data or read untill EOF
                if remain > 0 {
                    delegate?.onData(data: ptr, len: remain)
                }
                return len
            }
        }
        return len - remain
    }
    
    fileprivate func parseStartLine(line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        let tokens = line.components(separatedBy: " ")
        if tokens.count < 3 {
            return false
        }
        let str = "HTTP/"
        let r = Range(uncheckedBounds: (str.startIndex, str.endIndex))
        isRequest = tokens[0].compare(str, options: .caseInsensitive, range: r, locale: nil) != .orderedSame
        if isRequest {
            method = tokens[0]
            version = tokens[2]
            if let s = tokens[1].removingPercentEncoding {
                urlString = s
            } else {
                return false
            }
            url = URL(string: urlString)
            if url == nil {
                return false
            }
        } else {
            version = tokens[0]
            if let sc = Int(tokens[1]) {
                statusCode = sc
            } else {
                return false
            }
        }
        return true
    }
    
    fileprivate func parseHeadLine(line: String) -> Bool {
        /*let line = line.trimmingCharacters(in: .whitespaces)
        let tokens = line.components(separatedBy: ":")
        if tokens.count < 2 {
            return false
        }
        let name = tokens[0].trimmingCharacters(in: .whitespaces)
        let value = tokens[1].trimmingCharacters(in: .whitespaces)
        */
        let range = line.range(of: String(":"))
        guard let r = range else {
            return false
        }
        let index = line.index(before: r.upperBound)
        let name = line.substring(to: index).trimmingCharacters(in: .whitespaces)
        let value = line.substring(from: r.upperBound).trimmingCharacters(in: .whitespaces)
        headers[name.lowercased()] = value
        return true
    }
    
    fileprivate func parseChunk(data: UnsafeMutablePointer<Int8>, len: Int) -> Int {
        var ptr = data
        var remain = len
        while remain > 0 {
            switch chunkState {
            case .size:
                let ret = getLine(data: ptr, len: remain)
                ptr = ptr.advanced(by: ret.bytesRead)
                remain -= ret.bytesRead
                if var line = ret.line {
                    if !savedString.isEmpty {
                        line = savedString + line
                        savedString = ""
                    }
                    if line.isEmpty {
                        readState = .error
                        return len - remain
                    }
                    if let cs = Int(line, radix: 16) {
                        chunkSize = cs
                        if chunkSize == 0 {
                            chunkState = .trailer
                        } else {
                            chunkState = .data
                        }
                    } else {
                        readState = .error
                        return len - remain
                    }
                } else {
                    if !saveData(data: ptr, len: remain) {
                        readState = .error
                        return len - remain
                    }
                    return len
                }
                
            case .data:
                if chunkSize <= remain {
                    let notifySize = chunkSize
                    let notifyData = ptr
                    ptr = ptr.advanced(by: notifySize)
                    remain -= notifySize
                    totalBytesRead += notifySize
                    chunkSize = 0
                    chunkState = .data_cr
                    delegate?.onData(data: notifyData, len: notifySize)
                } else {
                    totalBytesRead += remain
                    chunkSize -= remain
                    delegate?.onData(data: ptr, len: remain)
                    return len
                }
                
            case .data_cr:
                if ptr[0] != kCR {
                    readState = .error
                    return len - remain
                } else {
                    ptr = ptr.advanced(by: 1)
                    remain -= 1
                    chunkState = .data_lf
                }
                
            case .data_lf:
                if ptr[0] != kLF {
                    readState = .error
                    return len - remain
                } else {
                    ptr = ptr.advanced(by: 1)
                    remain -= 1
                    chunkState = .size
                }
                
            case .trailer:
                let ret = getLine(data: ptr, len: remain)
                ptr = ptr.advanced(by: ret.bytesRead)
                remain -= ret.bytesRead
                if var line = ret.line {
                    if !savedString.isEmpty {
                        line = savedString + line
                        savedString = ""
                    }
                    if line.isEmpty {
                        readState = .done
                        onComplete()
                        return len - remain
                    }
                    // TODO: parse trailer
                } else {
                    if !saveData(data: ptr, len: remain) {
                        readState = .error
                        return len - remain
                    }
                    return len
                }
            }
        }
        return len
    }
    
    fileprivate func hasBody() -> Bool {
        if isChunked {
            return true
        }
        if let contentLength = contentLength {
            return contentLength > 0
        }
        if isRequest {
            return false
        } else { // read untill EOF
            return !((100 <= statusCode && statusCode <= 199) ||
                204 == statusCode || 304 == statusCode)
        }
    }
    
    fileprivate func readUntillEOF() -> Bool {
        return !isRequest && contentLength == nil && !isChunked &&
            !((100 <= statusCode && statusCode <= 199) ||
                204 == statusCode || 304 == statusCode)
    }
    
    func setEOF() -> Bool {
        if readUntillEOF() && readState == .body {
            readState = .done
            delegate?.onComplete()
            return true
        }
        return false
    }
    
    fileprivate func onHeaderComplete() {
        if let str = headers["content-length"] {
            contentLength = Int(str)
            infoTrace("onHeaderComplete, contentLength=\(contentLength)")
        }
        if let str = headers["transfer-encoding"] {
            isChunked = str == "chunked"
            infoTrace("onHeaderComplete, isChunked=\(isChunked)")
        }
        if headers["upgrade"] != nil {
            isUpgrade = true
        }
        delegate?.onHeaderComplete()
    }
    
    fileprivate func onComplete() {
        delegate?.onComplete()
    }
    
    fileprivate func saveData(data: UnsafeMutablePointer<Int8>, len: Int) -> Bool {
        if len + savedString.utf8.count > kMaxHttpHeadSize {
            return false
        }
        let str = String(bytesNoCopy: data, length: len, encoding: .utf8, freeWhenDone: false)
        if let str = str {
            savedString += str
        }
        return true
    }
    
    fileprivate func getLine(data: UnsafeMutablePointer<Int8>, len: Int) -> (line: String?, bytesRead: Int) {
        let str = String(bytesNoCopy: data, length: len, encoding: .ascii, freeWhenDone: false)
        guard let s = str else {
            return (nil, 0)
        }
        let range = s.range(of: String("\n"))
        guard let r = range else {
            return (nil, 0)
        }
        var index = s.index(before: r.upperBound)
        if s.distance(from: s.startIndex, to: index) > 0 && s[index] == "\r" {
            index = s.index(before: index)
        }
        return (s.substring(to: index), s.distance(from: s.startIndex, to: r.upperBound) + 1)
    }
}
