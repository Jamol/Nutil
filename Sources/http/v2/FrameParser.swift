//
//  FrameParser.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class FrameParser {
    typealias H2FrameCallback = (H2Frame) -> Bool
    typealias H2ErrorCallback = (FrameHeader, H2Error, Bool) -> Bool
    
    var cbFrame: H2FrameCallback?
    var cbError: H2ErrorCallback?
    
    fileprivate enum ReadState {
        case header, payload
    }
    
    fileprivate var maxFrameSize = 0
    
    fileprivate var readState = ReadState.header
    fileprivate var header = FrameHeader()
    fileprivate var payload: [UInt8] = []
    fileprivate var hdrBuffer: [UInt8] = []
    
    enum ParseState {
        case success, incomplete, failure, stopped
    }
    
    func setMaxFrameSize(_ frameSize: Int) {
        maxFrameSize = frameSize
    }
    
    func parseInputData(_ data: UnsafeMutableRawPointer, _ len: Int) -> ParseState {
        var ptr = data.assumingMemoryBound(to: UInt8.self)
        var remain = len
        while remain > 0 {
            if readState == .header {
                if hdrBuffer.count + remain < kH2FrameHeaderSize {
                    let bbuf = UnsafeBufferPointer<UInt8>(start: ptr, count: remain)
                    hdrBuffer.append(contentsOf: bbuf)
                    return .incomplete
                }
                if hdrBuffer.count > 0 {
                    let copyLen = kH2FrameHeaderSize - hdrBuffer.count
                    let bbuf = UnsafeBufferPointer<UInt8>(start: ptr, count: copyLen)
                    hdrBuffer.append(contentsOf: bbuf)
                    remain -= copyLen
                    ptr += copyLen
                    _ = header.decode(hdrBuffer, hdrBuffer.count)
                    hdrBuffer = []
                } else {
                    _ = header.decode(ptr, remain)
                    remain -= kH2FrameHeaderSize
                    ptr += kH2FrameHeaderSize
                }
                payload = []
                if header.length > maxFrameSize {
                    let streamErr = isStreamError(header, .frameSizeError)
                    _ = cbError?(header, .frameSizeError, streamErr)
                    return .failure
                }
                readState = .payload
            }
            if readState == .payload {
                if payload.isEmpty {
                    if remain >= header.length {
                        let parseState = parseFrame(header, ptr)
                        if parseState != .success {
                            return parseState
                        }
                        remain -= header.length
                        ptr += header.length
                        readState = .header
                    } else {
                        let bbuf = UnsafeBufferPointer<UInt8>(start: ptr, count: remain)
                        payload.append(contentsOf: bbuf)
                        return .incomplete
                    }
                } else {
                    var copyLen = header.length - payload.count
                    if copyLen > remain {
                        copyLen = remain
                    }
                    let bbuf = UnsafeBufferPointer<UInt8>(start: ptr, count: copyLen)
                    payload.append(contentsOf: bbuf)
                    if payload.count < header.length {
                        return .incomplete
                    }
                    remain -= copyLen
                    ptr += copyLen
                    readState = .header
                    let parseState = parseFrame(header, payload)
                    if parseState != .success {
                        return parseState
                    }
                    payload = []
                }
            }
        }
        return .success
    }
    
    fileprivate func parseFrame(_ hdr: FrameHeader, _ payload: UnsafeRawPointer) -> ParseState {
        var frame: H2Frame?
        switch hdr.type {
        case H2FrameType.data.rawValue:
            frame = dataFrame
        case H2FrameType.headers.rawValue:
            frame = hdrFrame
        case H2FrameType.priority.rawValue:
            frame = priFrame
        case H2FrameType.rststream.rawValue:
            frame = rstFrame
        case H2FrameType.settings.rawValue:
            frame = settingsFrame
        case H2FrameType.pushPromise.rawValue:
            frame = pushFrame
        case H2FrameType.ping.rawValue:
            frame = pingFrame
        case H2FrameType.goaway.rawValue:
            frame = goawayFrame
        case H2FrameType.windowUpdate.rawValue:
            frame = windowFrame
        case H2FrameType.continuation.rawValue:
            frame = continuationFrame
        default:
            warnTrace("FrameParser.handleFrame, invalid frame, type=\(hdr.type)")
        }
        
        if let frame = frame, let cb = cbFrame {
            let ptr = payload.assumingMemoryBound(to: UInt8.self)
            let err = frame.decode(hdr, ptr)
            if err == .noError {
                if !cb(frame) {
                    return .stopped
                }
            } else {
                // TODO: set correct value to isStream
                _ = cbError?(hdr, err, false)
                return .failure
            }
        }
        return .success
    }
    
    fileprivate func isStreamError(_ hdr: FrameHeader, _ err: H2Error) -> Bool {
        if hdr.streamId == 0 {
            return false
        }
        
        switch err {
        case .frameSizeError:
            return hdr.type != H2FrameType.headers.rawValue &&
                hdr.type != H2FrameType.settings.rawValue &&
                hdr.type != H2FrameType.pushPromise.rawValue &&
                hdr.type != H2FrameType.windowUpdate.rawValue
        case .protocolError:
            return false
        default:
            return true
        }
    }
    
    private let dataFrame = DataFrame()
    private let hdrFrame = HeadersFrame()
    private let priFrame = PriorityFrame()
    private let rstFrame = RSTStreamFrame()
    private let settingsFrame = SettingsFrame()
    private let pushFrame = PushPromiseFrame()
    private let pingFrame = PingFrame()
    private let goawayFrame = GoawayFrame()
    private let windowFrame = WindowUpdateFrame()
    private let continuationFrame = ContinuationFrame()
}
