//
//  H2Stream.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class H2Stream {
    fileprivate var streamId: UInt32 = 0
    fileprivate weak var conn: H2Connection?
    
    fileprivate var writeBlocked = false
    fileprivate var headersReceived = false
    fileprivate var headersEnd = false
    fileprivate var tailersReceived = false
    fileprivate var tailersEnd = false
    fileprivate let flowControl = FlowControl()
    
    fileprivate var endStreamSent_ = false
    fileprivate var endStreamReceived_ = false
    fileprivate var rstStreamSent_ = false
    fileprivate var rstStreamReceived_ = false
    
    typealias HeadersCallback = (NameValueArray, Bool) -> Void
    typealias DataCallback = (UnsafeMutableRawPointer?, Int, Bool) -> Void
    typealias RSTStreamCallback = (Int) -> Void
    typealias WriteCallback = () -> Void
    typealias PromiseCallback = (NameValueArray) -> Void
    
    var cbHeaders: HeadersCallback?
    var cbData: DataCallback?
    var cbReset: RSTStreamCallback?
    var cbWrite: WriteCallback?
    var cbPromise: PromiseCallback?
    
    enum State {
        case idle
        case reservedL
        case reservedR
        case open
        case halfClosedL
        case halfClosedR
        case closed
    }
    var state = State.idle
    
    init(_ streamId: UInt32, _ conn: H2Connection, _ initLocalWindowSize: Int, _ initRemoteWindowSize: Int) {
        self.streamId = streamId
        self.conn = conn
        flowControl.initLocalWindowSize(initLocalWindowSize)
        flowControl.initRemoteWindowSize(initRemoteWindowSize)
        flowControl.setLocalWindowStep(initLocalWindowSize)
        flowControl.cbUpdate = sendWindowUpdate
    }
    
    fileprivate func setState(_ state: State) {
        guard let c = conn else {
            self.state = state
            return
        }
        if !isInOpenState(self.state) && isInOpenState(state) {
            c.streamOpened(getStreamId())
        } else if isInOpenState(self.state) && state == .closed {
            c.streamClosed(getStreamId())
        }
        self.state = state
    }
    
    func getStreamId() -> UInt32 {
        return streamId
    }
    
    func sendPushPromise(_ headers: NameValueArray, _ hdrSize: Int, _ streamId: UInt32) -> KMError {
        if !isPromisedStream(getStreamId()) {
            return .invalidParam
        }
        if state != .idle {
            return .invalidState
        }
        let frame = PushPromiseFrame()
        frame.streamId = streamId
        frame.promisedStreamId = getStreamId()
        frame.addFlags(kH2FrameFlagEndHeaders)
        frame.setHeaders(headers, hdrSize)
        guard let c = conn else {
            return .invalidState
        }
        let ret = c.sendH2Frame(frame)
        setState(.reservedR)
        return ret
    }
    
    func sendHeaders(_ headers: NameValueArray, _ hdrSize: Int, _ endStream: Bool) -> KMError {
        let frame = HeadersFrame()
        frame.streamId = getStreamId()
        frame.addFlags(kH2FrameFlagEndHeaders)
        if endStream {
            frame.addFlags(kH2FrameFlagEndStream)
        }
        frame.setHeaders(headers, hdrSize)
        guard let c = conn else {
            return .invalidState
        }
        let ret = c.sendH2Frame(frame)
        if state == .idle {
            setState(.open)
        } else if state == .reservedL {
            setState(.halfClosedR)
        }
        if endStream {
            endStreamSent()
        }
        return ret
    }
    
    func sendData(_ data: UnsafeRawPointer?, _ len: Int, _ endStream: Bool) -> Int {
        if state == .halfClosedL || state == .closed {
            return -1
        }
        if writeBlocked {
            return 0
        }
        guard let c = conn else {
            return -1
        }
        let streamWindowSize = flowControl.remoteWindowSize
        let connWindowSize = c.remoteWindowSize
        let windowSize = min(streamWindowSize, connWindowSize)
        if windowSize == 0 && (!endStream || len != 0) {
            writeBlocked = true
            if connWindowSize == 0 {
                c.appendBlockedStream(getStreamId())
            }
            return 0
        }
        let slen = min(windowSize, len)
        let frame = DataFrame()
        frame.streamId = getStreamId()
        if endStream {
            frame.addFlags(kH2FrameFlagEndStream)
        }
        frame.setData(data, len)
        let ret = c.sendH2Frame(frame)
        if ret == .noError {
            if endStream {
                endStreamSent()
            }
            flowControl.bytesSent = slen
            if slen < len {
                writeBlocked = true
                c.appendBlockedStream(getStreamId())
            }
            return slen
        } else if ret == .again || ret == .bufferTooSmall {
            writeBlocked = true
            return 0
        }
        return -1
    }
    
    func sendWindowUpdate(delta: UInt32) -> KMError {
        if state == .closed || state == .halfClosedR {
            return .invalidState
        }
        guard let c = conn else {
            return .invalidState
        }
        return c.sendWindowUpdate(getStreamId(), delta: delta)
    }
    
    func close() {
        if state == .closed || state == .idle {
            return
        }
        streamError(.cancel)
        conn?.removeStream(getStreamId())
    }
    
    fileprivate func endStreamSent() {
        endStreamSent_ = true
        if state == .halfClosedR {
            setState(.closed);
        } else {
            setState(.halfClosedL);
        }
    }
    
    fileprivate func endStreamReceived() {
        endStreamReceived_ = true
        if state == .halfClosedL {
            setState(.closed)
        } else {
            setState(.halfClosedR)
        }
    }
    
    fileprivate func onHeaderCompleted(_ headers: NameValueArray, _ endStream: Bool) {
        if isPromisedStream(getStreamId()) {
            if state == .reservedR {
                // headers of server push request
                headersReceived = false
                headersEnd = false
                cbPromise?(headers)
            } else if state == .halfClosedL {
                // headers of server push response
                cbHeaders?(headers, endStream)
            }
        } else {
            cbHeaders?(headers, endStream)
        }
    }
    
    fileprivate func sendRSTStream(_ err: H2Error) {
        rstStreamSent_ = true
        
        let frame = RSTStreamFrame()
        frame.streamId = getStreamId()
        frame.errCode = UInt32(err.rawValue)
        _ = conn?.sendH2Frame(frame)
    }
    
    func connectionError(_ err: H2Error) {
        guard let c = conn else {
            return
        }
        c.connectionError(err)
    }
    
    func streamError(_ err: H2Error) {
        sendRSTStream(err)
        setState(.closed)
    }
    
    func handleDataFrame(_ frame: DataFrame) {
        if !verifyFrame(frame) {
            return
        }
        if isPromisedStream(getStreamId()) && state == .reservedR {
            // RFC 7540, 8.2
            // Promised request MUST NOT include a request body
            streamError(.protocolError)
            return
        }
        if state != .open && state != .halfClosedL {
            // RFC 7540, 6.1
            streamError(.streamClosed)
            return
        }
        let endStream = frame.hasEndStream()
        if endStream {
            infoTrace("H2Stream.handleDataFrame, END_STREAM received")
            endStreamReceived()
        }
        flowControl.bytesReceived = frame.size
        var data: UnsafeMutableRawPointer?
        if frame.data != nil {
            data = UnsafeMutableRawPointer(mutating: frame.data)
        }
        cbData?(data, frame.size, endStream)
    }
    
    func handleHeadersFrame(_ frame: HeadersFrame) {
        if !verifyFrame(frame) {
            return
        }
        var isTailer = false
        if headersReceived && (state == .open || state == .halfClosedL) {
            isTailer = true
            tailersReceived = true
            tailersEnd = frame.hasEndHeaders()
        } else {
            headersReceived = true
            headersEnd = frame.hasEndHeaders()
        }
        if state == .reservedR {
            setState(.halfClosedL)
        } else if state == .idle {
            setState(.open)
        }
        let endStream = frame.hasEndStream()
        if endStream {
            infoTrace("H2Stream.handleHeadersFrame, END_STREAM received")
            endStreamReceived()
        }
        if !isTailer && headersEnd {
            cbHeaders?(frame.headers, endStream)
        }
    }
    
    func handlePriorityFrame(_ frame: PriorityFrame) {
        if !verifyFrame(frame) {
            return
        }
        if frame.pri.streamId == getStreamId() {
            streamError(.protocolError)
            return
        }
    }
    
    func handleRSTStreamFrame(_ frame: RSTStreamFrame) {
        if !verifyFrame(frame) {
            return
        }
        if state == .closed {
            return
        }
        rstStreamReceived_ = true
        setState(.closed)
        cbReset?(Int(frame.errCode))
    }
    
    func handlePushFrame(_ frame: PushPromiseFrame) {
        if !verifyFrame(frame) {
            return
        }
        headersReceived = true
        headersEnd = frame.hasEndHeaders()
        setState(.reservedR)
        if headersEnd {
            cbHeaders?(frame.headers, false)
        }
    }
    
    func handleWindowUpdateFrame(_ frame: WindowUpdateFrame) {
        infoTrace("handleWindowUpdateFrame, streamId=\(frame.streamId), delta=\(frame.windowSizeIncrement), window=\(flowControl.remoteWindowSize)")
        if !verifyFrame(frame) {
            return
        }
        if state == .closed {
            return
        }
        if frame.windowSizeIncrement == 0 {
            // RFC 7540, 6.9
            streamError(.protocolError)
            return
        }
        let needOnWrite = flowControl.remoteWindowSize == 0
        flowControl.updateRemoteWindowSize(Int(frame.windowSizeIncrement))
        if needOnWrite && state != .idle && flowControl.remoteWindowSize > 0 {
            onWrite()
        }
    }
    
    func handleContinuationFrame(_ frame: ContinuationFrame) {
        if !verifyFrame(frame) {
            return
        }
        if state != .open || state != .halfClosedL {
            // invalid status
            return
        }
        if (!headersReceived || headersEnd) && (!tailersReceived || tailersEnd) {
            // PROTOCOL_ERROR
            connectionError(.protocolError)
            return
        }
        let isTailer = headersEnd
        let endStream = frame.hasEndStream()
        if endStream {
            infoTrace("H2Stream.handleContinuationFrame, END_STREAM received")
            endStreamReceived()
        }
        let endHeaders = frame.hasEndHeaders()
        if endHeaders {
            if !isTailer {
                headersEnd = true
            } else {
                tailersEnd = true
            }
        }
        if !isTailer && headersEnd {
            cbHeaders?(frame.headers, endStream)
        }
    }
    
    func updateRemoteWindowSize(_ delta: Int) {
        flowControl.updateRemoteWindowSize(delta)
    }
    
    func verifyFrame(_ frame: H2Frame) -> Bool {
        // RFC 7540, 5.1
        switch state {
        case .idle:
            if frame.type() != .headers &&
                frame.type() != .priority &&
                frame.type() != .pushPromise {
                connectionError(.protocolError)
                return false
            }
        case .reservedL:
            if frame.type() != .rststream &&
                frame.type() != .priority &&
                frame.type() != .windowUpdate {
                connectionError(.protocolError)
                return false
            }
        case .reservedR:
            if frame.type() != .headers &&
                frame.type() != .rststream &&
                frame.type() != .priority {
                connectionError(.protocolError)
                return false
            }
        case .open:
            return true
        case .halfClosedL:
            return true
        case .halfClosedR:
            if frame.type() != .rststream &&
                frame.type() != .priority &&
                frame.type() != .windowUpdate {
                streamError(.streamClosed)
                return false
            }
        case .closed:
            if rstStreamReceived_ && frame.type() != .priority {
                streamError(.streamClosed)
                return false
            }
            if endStreamReceived_ && frame.type() != .priority {
                streamError(.streamClosed)
                return false
            }
        default:
            break
        }
        return true
    }
    
    func isInOpenState(_ state: State) -> Bool {
        return state == .open || state == .halfClosedL || state == .halfClosedR
    }
    
    func onWrite() {
        writeBlocked = false
        cbWrite?()
    }
    
    func onError(_ err: Int) {
        conn = nil
        cbReset?(err)
    }
}

extension H2Stream {
    @discardableResult func onData(_ cb: @escaping (UnsafeMutableRawPointer?, Int, Bool) -> Void) -> Self {
        cbData = cb
        return self
    }
    
    @discardableResult func onHeaders(_ cb: @escaping HeadersCallback) -> Self {
        cbHeaders = cb
        return self
    }
    
    @discardableResult func onRSTStream(_ cb: @escaping RSTStreamCallback) -> Self {
        cbReset = cb
        return self
    }
    
    @discardableResult func onWrite(_ cb: @escaping () -> Void) -> Self {
        cbWrite = cb
        return self
    }
    
    @discardableResult func onPromise(_ cb: @escaping PromiseCallback) -> Self {
        cbPromise = cb
        return self
    }
}

typealias H2StreamMap = [UInt32: H2Stream]
