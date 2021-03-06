//
//  H2Connection.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class H2Connection : TcpConnection, HttpParserDelegate {
    
    fileprivate let httpParser = HttpParser()
    fileprivate let frameParser = FrameParser()
    fileprivate let hpEncoder = HPacker()
    fileprivate let hpDecoder = HPacker()
    fileprivate let flowControl = FlowControl()
    
    fileprivate  var connKey = ""
    enum State : Int {
        case idle
        case connecting
        case upgrading
        case handshake
        case open
        case error
        case closed
    }
    fileprivate var state = State.idle
    var isReady: Bool {
        return state == .open
    }
    
    fileprivate var streams: H2StreamMap = [:]
    fileprivate var promisedStreams: H2StreamMap = [:]
    fileprivate var blockedStreams: [UInt32: UInt32] = [:]
    
    var cmpPreface = ""  // server only
    
    fileprivate var maxLocalFrameSize = 65536
    fileprivate var maxRemoteFrameSize = kH2DefaultFrameSize
    fileprivate var initRemoteWindowSize = kH2DefaultWindowSize
    fileprivate var initLocalWindowSize = LOCAL_STREAM_INITIAL_WINDOW_SIZE  // initial local stream window size
    
    fileprivate var nextStreamId: UInt32 = 0
    fileprivate var lastStreamId: UInt32 = 0
    
    fileprivate var maxConcurrentStreams = 128
    fileprivate var openedStreamCount = 0
    
    fileprivate var expectContinuationFrame = false
    fileprivate var streamIdOfExpectedContinuation: UInt32 = 0
    fileprivate var headersBlockBuffer = [UInt8]()
    
    fileprivate var prefaceReceived = false
    
    typealias AcceptCallback = (UInt32) -> Bool
    typealias ErrorCallback = (Int) -> Void
    typealias ConnectCallback = (KMError) -> Void
    
    var cbAccept: AcceptCallback?
    var cbError: ErrorCallback?
    fileprivate var connectListeners: [Int : ConnectCallback] = [:]
    
    var remoteWindowSize: Int {
        return flowControl.remoteWindowSize
    }
    
    override init () {
        super.init()
        flowControl.initLocalWindowSize(LOCAL_CONN_INITIAL_WINDOW_SIZE)
        flowControl.setMinLocalWindowSize(initLocalWindowSize);
        flowControl.setLocalWindowStep(LOCAL_CONN_INITIAL_WINDOW_SIZE)
        flowControl.cbUpdate = { (delta: UInt32) -> KMError in
            return self.sendWindowUpdate(0, delta: delta)
        }
        frameParser.setMaxFrameSize(maxLocalFrameSize)
        cmpPreface = kClientConnectionPreface
        httpParser.delegate = self
        frameParser.cbFrame = onFrame
        frameParser.cbError = onFrameError
    }
    
    fileprivate func cleanup() {
        setState(.closed)
        super.close()
        removeSelf()
    }
    
    fileprivate func setState(_ state: State) {
        self.state = state
    }
    
    func setConnectionKey(_ connKey: String) {
        self.connKey = connKey
    }
    
    func getConnectionKey() -> String {
        return connKey;
    }
    
    override func connect(_ addr: String, _ port: Int) -> KMError {
        if state != .idle {
            return .invalidState
        }
        
        nextStreamId = 1
        setState(.connecting)
        var port = port
        if port == 0 {
            if socket.sslEnabled() {
                port = 443
            } else {
                port = 80
            }
        }
        
        if socket.sslEnabled() {
            socket.setAlpnProtocols(alpnProtos)
        }
        
        return super.connect(addr, port)
    }
    
    override func attachFd(_ fd: SOCKET_FD, _ initData: UnsafeRawPointer?, _ initSize: Int) -> KMError {
        nextStreamId = 2
        let ret = super.attachFd(fd, initData, initSize)
        if ret == .noError {
            if socket.sslEnabled() {
                // waiting for client preface
                setState(.handshake)
                sendPreface()
            } else {
                // waiting for http upgrade reuqest
                setState(.upgrading)
            }
        }
        return ret
    }
    
    func attachStream(streamId: UInt32, rsp: Http2Response) -> KMError {
        if isPromisedStream(streamId) {
            return .invalidParam
        }
        return rsp.attachStream(self, streamId)
    }
    
    override func close() {
        infoTrace("H2Connection.close")
        if state < .open || state == .open{
            sendGoaway(.noError)
        }
        setState(.closed)
        cleanup()
    }
    
    func sendH2Frame(_ frame: H2Frame) -> KMError {
        if !sendBufferEmpty() && !isControlFrame(frame) && !frame.hasEndStream() {
            appendBlockedStream(frame.streamId)
            return .again
        }
        if isControlFrame(frame) {
            infoTrace("H2Connection.sendH2Frame, type=\(frame.type()), streamId=\(frame.streamId), flags=\(frame.getFlags())")
        } else if frame.hasEndStream() {
            infoTrace("H2Connection.sendH2Frame, end stream, type=\(frame.type()), streamId=\(frame.streamId)")
        }
        
        if frame.type() == .headers {
            let headersFrame = frame as! HeadersFrame
            return sendHeadersFrame(headersFrame)
        } else if frame.type() == .data {
            if flowControl.remoteWindowSize < frame.getPayloadLength() {
                infoTrace("H2Connection.sendH2Frame, BUFFER_TOO_SMALL, win=\(flowControl.remoteWindowSize), len=\(frame.getPayloadLength())")
                appendBlockedStream(frame.streamId)
                return .bufferTooSmall
            }
            flowControl.bytesSent = frame.getPayloadLength()
        } else if frame.type() == .windowUpdate && frame.streamId != 0 {
            
        }
        let payloadSize = frame.calcPayloadSize()
        let frameSize = payloadSize + kH2FrameHeaderSize
        
        var buf = Array<UInt8>(repeating: 0, count: frameSize)
        //let ret = frame.encode(&buf, frameSize)
        let ret = buf.withUnsafeMutableBufferPointer {
            return frame.encode($0.baseAddress!, frameSize)
        }
        if ret < 0 {
            errTrace("H2Connection.sendH2Frame, failed to encode frame, type=\(frame.type())")
            return .invalidParam
        }
        appendBufferedData(buf)
        return sendBufferedData()
    }
    
    func sendHeadersFrame(_ frame: HeadersFrame) -> KMError {
        let pri = H2Priority()
        frame.pri = pri
        var len1 = kH2FrameHeaderSize
        if frame.hasPriority() {
            len1 += kH2PriorityPayloadSize
        }
        let hdrSize = frame.hsize
        
        let hpackSize = hdrSize * 3 / 2
        let frameSize = len1 + hpackSize
        var buf = Array<UInt8>(repeating: 0, count: frameSize)
        let ret = buf.withUnsafeMutableBufferPointer { (base) -> KMError in
            let ptr = base.baseAddress!
            var ret = hpEncoder.encode(frame.headers, ptr + len1, frameSize)
            if ret < 0 {
                return KMError.failed
            }
            let bsize = ret
            ret = frame.encode(ptr, len1, bsize)
            assert(ret == len1)
            let realSize = len1 + bsize
            appendBufferedData(ptr, realSize)
            return KMError.noError
        }
        if ret != .noError {
            return ret
        }
        return sendBufferedData()
    }
    
    func createStream() -> H2Stream {
        let stream = H2Stream(nextStreamId, self, initLocalWindowSize, initRemoteWindowSize)
        nextStreamId += 2
        addStream(stream)
        return stream
    }
    
    fileprivate func createStream(_ streamId: UInt32) -> H2Stream {
        let stream = H2Stream(streamId, self, initLocalWindowSize, initRemoteWindowSize)
        addStream(stream)
        return stream
    }
    
    fileprivate func handleDataFrame(_ frame: DataFrame) {
        if frame.streamId == 0 {
            // RFC 7540, 6.1
            connectionError(.protocolError)
            return
        }
        flowControl.bytesReceived = frame.getPayloadLength()
        let stream = getStream(frame.streamId)
        if let stream = stream {
            stream.handleDataFrame(frame)
        } else {
            warnTrace("H2Connection.handleDataFrame, no stream, streamId=\(frame.streamId)")
        }
    }
    
    fileprivate func handleHeadersFrame(_ frame: HeadersFrame) {
        infoTrace("H2Connection.handleHeadersFrame, streamId=\(frame.streamId), flags=\(frame.getFlags())")
        if frame.streamId == 0 {
            // RFC 7540, 6.2
            connectionError(.protocolError)
            return
        }
        var stream = getStream(frame.streamId)
        if stream == nil {
            if frame.streamId < lastStreamId {
                // RFC 7540, 5.1.1
                connectionError(.protocolError)
                return
            }
            if openedStreamCount + 1 > maxConcurrentStreams {
                warnTrace("handleHeadersFrame, too many concurrent streams, streamId=\(frame.streamId), opened=\(openedStreamCount), max=\(maxConcurrentStreams)")
                //RFC 7540, 5.1.2
                streamError(frame.streamId, .refusedStream)
                return
            }
            if !isServer {
                warnTrace("H2Connection.handleHeadersFrame, no local stream or promised stream, streamId=\(frame.streamId)")
                return
            }
        }
        if frame.hasEndHeaders() {
            if frame.block == nil {
                return
            }
            let hdrData = frame.block!.assumingMemoryBound(to: UInt8.self)
            var headers: NameValueArray = []
            var ret: Int = -1
            (ret, headers) = hpDecoder.decode(hdrData, frame.bsize)
            if ret < 0 {
                warnTrace("H2Connection.handleHeadersFrame, hpack decode failed")
                // RFC 7540, 4.3
                connectionError(.compressionError)
                return
            }
            frame.setHeaders(headers, 0)
        } else {
            expectContinuationFrame = true
            streamIdOfExpectedContinuation = frame.streamId
            let hdrData = frame.block!.assumingMemoryBound(to: UInt8.self)
            headersBlockBuffer = Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(hdrData), count: frame.bsize))
        }
        
        if stream == nil {
            // new stream arrived on server side
            stream = createStream(frame.streamId)
            if cbAccept != nil && !cbAccept!(frame.streamId) {
                removeStream(frame.streamId)
                return
            }
            lastStreamId = frame.streamId
        }
        
        stream!.handleHeadersFrame(frame)
    }
    
    fileprivate func handlePriorityFrame(_ frame: PriorityFrame) {
        infoTrace("H2Connection.handlePriorityFrame, streamId=\(frame.streamId), dep=\(frame.pri.streamId), weight=\(frame.pri.weight)")
        if frame.streamId == 0 {
            // RFC 7540, 6.3
            connectionError(.protocolError)
            return
        }
        let stream = getStream(frame.streamId)
        stream?.handlePriorityFrame(frame)
    }
    
    fileprivate func handleRSTStreamFrame(_ frame: RSTStreamFrame) {
        infoTrace("H2Connection.handleRSTStreamFrame, streamId=\(frame.streamId), err=\(frame.errCode)")
        if frame.streamId == 0 {
            // RFC 7540, 6.4
            connectionError(.protocolError)
            return
        }
        let stream = getStream(frame.streamId)
        if let stream = stream {
            stream.handleRSTStreamFrame(frame)
        }
    }
    
    fileprivate func handleSettingsFrame(_ frame: SettingsFrame) {
        infoTrace("H2Connection.handleSettingsFrame, streamId=\(frame.streamId), count=\(frame.params.count)")
        if frame.streamId != 0 {
            // RFC 7540, 6.5
            connectionError(.protocolError)
            return
        }
        if frame.ack {
            if frame.params.count != 0 {
                // RFC 7540, 6.5
                connectionError(.frameSizeError)
                return
            }
            return
        } else {
            // send setings ack
            let settings = SettingsFrame()
            settings.streamId = frame.streamId
            settings.ack = true
            _ = sendH2Frame(settings)
        }
        applySettings(frame.params)
        if state < .open {
            // first frame must be SETTINGS
            prefaceReceived = true
            if state == .handshake && sendBufferEmpty() {
                onStateOpen()
            }
        }
    }
    
    fileprivate func handlePushFrame(_ frame: PushPromiseFrame) {
        infoTrace("H2Connection.handlePushFrame, streamId=\(frame.streamId), promStreamId=\(frame.promisedStreamId), bsize=\(frame.bsize), flags=\(frame.getFlags())")
        if frame.streamId == 0 {
            // RFC 7540, 6.6
            connectionError(.protocolError)
            return
        }
        
        // TODO: if SETTINGS_ENABLE_PUSH was set to 0 and got the ack,
        // then response connection error of type PROTOCOL_ERROR
        
        if !isPromisedStream(frame.promisedStreamId) {
            warnTrace("H2Connection.handlePushFrame, invalid stream id")
            // RFC 7540, 5.1.1
            connectionError(.protocolError)
            return
        }
        let associatedStream = getStream(frame.streamId)
        if associatedStream == nil {
            connectionError(.protocolError)
            return
        }
        if associatedStream!.state != .open && associatedStream!.state != .halfClosedL {
            // RFC 7540, 6.6
            connectionError(.protocolError)
            return
        }
        
        if frame.hasEndHeaders() {
            if frame.block == nil {
                return
            }
            let hdrData = frame.block!.assumingMemoryBound(to: UInt8.self)
            var headers: NameValueArray = []
            var ret: Int = -1
            (ret, headers) = hpDecoder.decode(hdrData, frame.bsize)
            if ret < 0 {
                warnTrace("H2Connection.handlePushFrame, hpack decode failed")
                // RFC 7540, 4.3
                connectionError(.compressionError)
                return
            }
            frame.setHeaders(headers, 0)
        } else {
            expectContinuationFrame = true
            streamIdOfExpectedContinuation = frame.promisedStreamId
            let hdrData = frame.block!.assumingMemoryBound(to: UInt8.self)
            headersBlockBuffer = Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(hdrData), count: frame.bsize))
        }
        
        let stream = createStream(frame.promisedStreamId)
        stream.handlePushFrame(frame)
    }
    
    fileprivate func handlePingFrame(_ frame: PingFrame) {
        infoTrace("H2Connection.handlePingFrame, streamId=\(frame.streamId)")
        if frame.streamId != 0 {
            // RFC 7540, 6.7
            connectionError(.protocolError)
            return
        }
        if !frame.ack {
            let pingFrame = PingFrame()
            pingFrame.streamId = 0
            pingFrame.ack = true
            pingFrame.data = frame.data
            _ = sendH2Frame(pingFrame)
        }
    }
    
    fileprivate func handleGoawayFrame(_ frame: GoawayFrame) {
        if frame.streamId != 0 {
            // RFC 7540, 6.8
            connectionError(.protocolError)
            return
        }
        super.close()
        var sss = streams
        streams = [:]
        for kv in sss {
            kv.value.onError(Int(frame.errCode))
        }
        sss = promisedStreams
        promisedStreams = [:]
        for kv in sss {
            kv.value.onError(Int(frame.errCode))
        }
        let cb = cbError
        cbError = nil
        removeSelf()
        cb?(Int(frame.errCode))
    }
    
    fileprivate func handleWindowUpdateFrame(_ frame: WindowUpdateFrame) {
        if frame.windowSizeIncrement == 0 {
            // RFC 7540, 6.9
            streamError(frame.streamId, .protocolError)
            return
        }
        if flowControl.remoteWindowSize + Int(frame.windowSizeIncrement) > kH2MaxWindowSize {
            if frame.streamId == 0 {
                connectionError(.flowControlError)
            } else {
                streamError(frame.streamId, .flowControlError)
            }
            return
        }
        if frame.streamId == 0 {
            infoTrace("handleWindowUpdateFrame, streamId=\(frame.streamId), delta=\(frame.windowSizeIncrement), window=\(flowControl.remoteWindowSize)")
            if frame.windowSizeIncrement == 0 {
                connectionError(.protocolError)
                return
            }
            let needNotify = !blockedStreams.isEmpty
            flowControl.updateRemoteWindowSize(Int(frame.windowSizeIncrement))
            if needNotify && flowControl.remoteWindowSize > 0 {
                notifyBlockedStreams()
            }
        } else {
            var stream = getStream(frame.streamId)
            if stream == nil && isServer {
                // new stream arrived on server side
                stream = createStream(frame.streamId)
                if cbAccept != nil && !cbAccept!(frame.streamId) {
                    removeStream(frame.streamId)
                    return
                }
                lastStreamId = frame.streamId
            }
            stream?.handleWindowUpdateFrame(frame)
        }
    }
    
    fileprivate func handleContinuationFrame(_ frame: ContinuationFrame) {
        infoTrace("H2Connection.handleContinuationFrame, streamId=\(frame.streamId)")
        if frame.streamId == 0 {
            // RFC 7540, 6.10
            connectionError(.protocolError)
            return
        }
        if !expectContinuationFrame {
            // RFC 7540, 6.10
            connectionError(.protocolError)
            return
        }
        if let stream = getStream(frame.streamId), frame.bsize > 0 {
            let hdrData = frame.block!.assumingMemoryBound(to: UInt8.self)
            headersBlockBuffer += Array(UnsafeBufferPointer(start: hdrData, count: frame.bsize))
            if frame.hasEndHeaders() {
                var headers: NameValueArray = []
                var ret: Int = -1
                (ret, headers) = hpDecoder.decode(headersBlockBuffer, headersBlockBuffer.count)
                if ret < 0 {
                    errTrace("H2Connection.handleContinuationFrame, hpack decode failed")
                    // RFC 7540, 4.3
                    connectionError(.compressionError)
                    return
                }
                frame.headers = headers
                expectContinuationFrame = false
                headersBlockBuffer = []
            }
            stream.handleContinuationFrame(frame)
        }
    }
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        var data = data
        var len = len
        if state == .open {
            return parseInputData(data, len)
        } else if state == .upgrading {
            let ret = httpParser.parse(data: data, len: len)
            if state == .error {
                return false
            }
            if state == .closed {
                return true
            }
            if ret >= len {
                return true
            }
            // residual data, should be preface
            len -= ret
            data += ret
        }
        
        if state == .handshake {
            if isServer && cmpPreface.utf8.count > 0 {
                let cmpSize = min(cmpPreface.utf8.count, len)
                if memcmp(cmpPreface, data, cmpSize) != 0 {
                    errTrace("H2Connection.handleInputData, invalid protocol")
                    setState(.closed)
                    cleanup()
                    return false
                }
                let index = cmpPreface.index(cmpPreface.startIndex, offsetBy: cmpSize)
                cmpPreface = String(cmpPreface[index...])
                if !cmpPreface.isEmpty {
                    return true // need more data
                }
                len -= cmpSize
                data += cmpSize
            }
            // expect a SETTINGS frame
            return parseInputData(data, len)
        } else {
            warnTrace("H2Connection.handleInputData, invalid state: \(state)")
        }
        return true
    }
    
    fileprivate func parseInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        let parseState = frameParser.parseInputData(data, len)
        if state == .error || state == .closed {
            return false
        }
        if parseState == .failure || parseState == .stopped {
            errTrace("H2Connection.parseInputData, failed, len=\(len), state=\(state)")
            setState(.closed)
            cleanup()
            return false
        }
        return true
    }
    
    fileprivate func onFrame(_ frame: H2Frame) -> Bool {
        if state == .handshake && frame.type() != .settings {
            // RFC 7540, 3.5
            // the first frame must be SETTINGS, otherwise PROTOCOL_ERROR on connection
            errTrace("onFrame, the first frame is not SETTINGS, type=\(frame.type())")
            state = .closed
            cbError?(Int(H2Error.protocolError.rawValue))
            return false
        }
        if expectContinuationFrame &&
            (frame.type() != .continuation ||
             frame.streamId != streamIdOfExpectedContinuation) {
            connectionError(.protocolError)
            return false
        }
        switch frame.type() {
        case .data:
            handleDataFrame(frame as! DataFrame)
        case .headers:
            handleHeadersFrame(frame as! HeadersFrame)
        case .priority:
            handlePriorityFrame(frame as! PriorityFrame)
        case .rststream:
            handleRSTStreamFrame(frame as! RSTStreamFrame)
        case .settings:
            handleSettingsFrame(frame as! SettingsFrame)
        case .pushPromise:
            handlePushFrame(frame as! PushPromiseFrame)
        case .ping:
            handlePingFrame(frame as! PingFrame)
        case .goaway:
            handleGoawayFrame(frame as! GoawayFrame)
        case .windowUpdate:
            handleWindowUpdateFrame(frame as! WindowUpdateFrame)
        case .continuation:
            handleContinuationFrame(frame as! ContinuationFrame)
        }
        return true
    }
    
    fileprivate func onFrameError(_ hdr: FrameHeader, _ err: H2Error, stream: Bool) -> Bool {
        errTrace("H2Connection.onFrameError, streamId=\(hdr.streamId), type=\(hdr.type), err=\(err)")
        if stream {
            streamError(hdr.streamId, err)
        } else {
            connectionError(err)
        }
        return true
    }
    
    fileprivate func addStream(_ stream: H2Stream) {
        infoTrace("H2Connection.addStream, streamId=\(stream.getStreamId())")
        if isPromisedStream(stream.getStreamId()) {
            promisedStreams[stream.getStreamId()] = stream
        } else {
            streams[stream.getStreamId()] = stream
        }
    }
    
    func getStream(_ streamId: UInt32) -> H2Stream? {
        if isPromisedStream(streamId) {
            return promisedStreams[streamId]
        } else {
            return streams[streamId]
        }
    }
    
    func removeStream(_ streamId: UInt32) {
        infoTrace("H2Connection.removeStream, streamId=\(streamId)")
        if isPromisedStream(streamId) {
            promisedStreams.removeValue(forKey: streamId)
        } else {
            streams.removeValue(forKey: streamId)
        }
    }
    
    func addConnectListener(_ uid: Int, _ cb: @escaping ConnectCallback) {
        connectListeners[uid] = cb
    }
    
    func removeConnectListener(_ uid: Int) {
        connectListeners.removeValue(forKey: uid)
    }
    
    func appendBlockedStream(_ streamId: UInt32) {
        blockedStreams[streamId] = streamId
    }
    
    fileprivate func notifyBlockedStreams() {
        if !sendBufferEmpty() || remoteWindowSize == 0 {
            return
        }
        var bstreams = blockedStreams
        blockedStreams = [:]
        
        while !bstreams.isEmpty && sendBufferEmpty() && remoteWindowSize > 0 {
            let streamId = bstreams.first!.key
            bstreams.removeValue(forKey: streamId)
            let stream = getStream(streamId)
            if let stream = stream {
                stream.onWrite()
            }
        }
        for kv in bstreams {
            blockedStreams[kv.key] = kv.value
        }
    }
    
    func sync() -> Bool {
        return false
    }
    
    func async() -> Bool {
        return false
    }
    
    fileprivate func buildUpgradeRequest() -> String {
        var params: H2SettingArray = []
        params.append((H2SettingsID.initialWindowSize.rawValue, UInt32(initLocalWindowSize)))
        params.append((H2SettingsID.maxFrameSize.rawValue, 65536))
        let psize = 2 * kH2SettingItemSize
        var pbuff = Array<UInt8>(repeating: 0, count: psize)
        let settingsFrame = SettingsFrame()
        //_ = settingsFrame.encodePayload(&pbuff, psize, params)
        _ = pbuff.withUnsafeMutableBufferPointer {
            return settingsFrame.encodePayload($0.baseAddress!, psize, params)
        }
        let dd = Data(bytes: pbuff)
        let settingsStr = dd.base64EncodedString()
        var req = "GET / HTTP/1.1\r\n"
        req += "Host: \(super.host)\r\n"
        req += "Connection: Upgrade, HTTP2-Settings\r\n"
        req += "Upgrade: h2c\r\n"
        req += "HTTP2-Settings: \(settingsStr)\r\n"
        req += "\r\n"
        return req
    }
    
    fileprivate func buildUpgradeResponse() -> String {
        var rsp = "HTTP/1.1 101 Switching Protocols\r\n"
        rsp += "Connection: Upgrade\r\n"
        rsp += "Upgrade: \(httpParser.headers["Upgrade"]!)\r\n"
        rsp += "\r\n"
        return rsp
    }
    
    fileprivate func sendUpgradeRequest() {
        let req = buildUpgradeRequest()
        appendBufferedData(req, req.utf8.count)
        setState(.upgrading)
        _ = sendBufferedData()
    }
    
    fileprivate func sendUpgradeResponse() {
        let rsp = buildUpgradeResponse()
        appendBufferedData(rsp, rsp.utf8.count)
        setState(.upgrading)
        _ = sendBufferedData()
        if sendBufferEmpty() {
            sendPreface()
        }
    }
    
    fileprivate func sendPreface() {
        setState(.handshake)
        var params: H2SettingArray = []
        params.append((H2SettingsID.initialWindowSize.rawValue, UInt32(initLocalWindowSize)))
        params.append((H2SettingsID.maxFrameSize.rawValue, 65536))
        var settingsSize = kH2FrameHeaderSize + params.count * kH2SettingItemSize
        var encodedLen = 0
        if !isServer {
            appendBufferedData(kClientConnectionPreface, kClientConnectionPreface.utf8.count)
            encodedLen += kClientConnectionPreface.utf8.count
        } else {
            params.append((H2SettingsID.maxConcurrentStreams.rawValue, 128))
            settingsSize += kH2SettingItemSize
        }
        
        let settingsFrame = SettingsFrame()
        settingsFrame.streamId = 0
        settingsFrame.params = params
        var buf = Array<UInt8>(repeating: 0, count: settingsSize)
        //var ret = settingsFrame.encode(&buf, settingsSize)
        var ret = buf.withUnsafeMutableBufferPointer {
            return settingsFrame.encode($0.baseAddress!, settingsSize)
        }
        if ret < 0 {
            errTrace("sendPreface, failed to encode setting frame")
            return
        }
        appendBufferedData(buf)
        
        let frame = WindowUpdateFrame()
        frame.streamId = 0
        frame.windowSizeIncrement = UInt32(flowControl.localWindowSize)
        buf = Array<UInt8>(repeating: 0, count: kH2WindowUpdateFrameSize)
        ret = buf.withUnsafeMutableBufferPointer {
            return frame.encode($0.baseAddress!, kH2WindowUpdateFrameSize)
        }
        if ret < 0 {
            errTrace("sendPreface, failed to encode window update frame")
            return
        }
        appendBufferedData(buf)
        _ = sendBufferedData()
        if sendBufferEmpty() && prefaceReceived {
            onStateOpen()
        }
    }
    
    func sendWindowUpdate(_ streamId: UInt32, delta: UInt32) -> KMError {
        let frame = WindowUpdateFrame()
        frame.streamId = streamId
        frame.windowSizeIncrement = delta
        return sendH2Frame(frame)
    }
    
    func sendGoaway(_ err: H2Error) {
        let frame = GoawayFrame()
        frame.errCode = UInt32(err.rawValue)
        frame.streamId = 0
        frame.lastStreamId = lastStreamId
        _ = sendH2Frame(frame)
    }
    
    fileprivate func applySettings(_ params: H2SettingArray) {
        for kv in params {
            infoTrace("applySettings, id=\(kv.key), value=\(kv.value)")
            switch kv.key {
            case H2SettingsID.headerTableSize.rawValue:
                hpDecoder.setMaxTableSize(Int(kv.value))
            case H2SettingsID.initialWindowSize.rawValue:
                if kv.value > kH2MaxWindowSize {
                    // RFC 7540, 6.5.2
                    connectionError(.flowControlError)
                    return
                }
                updateInitialWindowSize(Int(kv.value))
            case H2SettingsID.maxFrameSize.rawValue:
                if kv.value < kH2DefaultFrameSize || kv.value > kH2MaxFrameSize {
                    // RFC 7540, 6.5.2
                    connectionError(.protocolError)
                    return
                }
                maxRemoteFrameSize = Int(kv.value)
            case H2SettingsID.maxConcurrentStreams.rawValue:
                break
            case H2SettingsID.enablePush.rawValue:
                if kv.value != 0 && kv.value != 1 {
                    // RFC 7540, 6.5.2
                    connectionError(.protocolError)
                    return
                }
                break
            default:
                break
            }
        }
    }
    
    fileprivate func updateInitialWindowSize(_ ws: Int) {
        if ws != initRemoteWindowSize {
            let delta = ws - initRemoteWindowSize
            initRemoteWindowSize = ws
            for kv in streams {
                kv.value.updateRemoteWindowSize(delta)
            }
            for kv in promisedStreams {
                kv.value.updateRemoteWindowSize(delta)
            }
        }
    }
    
    func connectionError(_ err: H2Error) {
        sendGoaway(err)
        setState(.closed)
        cbError?(Int(err.rawValue))
    }
    
    fileprivate func streamError(_ streamId: UInt32, _ err: H2Error) {
        let stream = getStream(streamId)
        if stream != nil {
            stream!.streamError(err)
        } else {
            let frame = RSTStreamFrame()
            frame.streamId = streamId
            frame.errCode = UInt32(err.rawValue)
            _ = sendH2Frame(frame)
        }
    }
    
    func streamOpened(_ streamId: UInt32) {
        openedStreamCount += 1
    }
    
    func streamClosed(_ streamId: UInt32) {
        openedStreamCount -= 1
    }
    
    fileprivate func isControlFrame(_ frame: H2Frame) -> Bool {
        return frame.type() != .data
    }
    
    override func handleOnConnect(err: KMError) {
        infoTrace("H2Connection.handleOnConnect, err=\(err)")
        if err != .noError {
            onConnectError(err)
            return
        }
        if socket.sslEnabled() {
            sendPreface()
            return
        }
        nextStreamId += 2 // stream id 1 is for upgrade request
        sendUpgradeRequest()
    }
    
    override func handleOnSend() {
        // send_buffer_ must be empty
        if isServer && state == .upgrading {
            // upgrade response is sent out, waiting for client preface
            setState(.handshake)
            sendPreface()
        } else if state == .handshake && prefaceReceived {
            onStateOpen()
        }
        if state == .open {
            notifyBlockedStreams()
        }
    }
    
    override func handleOnError(err: KMError) {
        onError(err: err)
    }
    
    func onHttpData(data: UnsafeMutableRawPointer, len: Int) {
        //infoTrace("onData, len=\(len), total=\(parser.bodyBytesRead)")
    }
    
    func onHttpHeaderComplete() {
        infoTrace("H2Connection.onHttpHeaderComplete")
        if !httpParser.isUpgradeTo(proto: "h2c") {
            errTrace("H2Connection.onHeaderComplete, not HTTP2 upgrade response")
        }
    }
    
    func onHttpComplete() {
        infoTrace("H2Connection.onHttpComplete")
        if httpParser.isRequest {
            _ = handleUpgradeRequest()
        } else {
            _ = handleUpgradeResponse()
        }
    }
    
    func onHttpError(err: KMError) {
        infoTrace("H2Connection.onHttpError, err=\(err)")
        setState(.error)
        onConnectError(.failed)
    }
    
    fileprivate func handleUpgradeRequest() -> KMError {
        if !httpParser.isUpgradeTo(proto: "h2c") {
            setState(.error)
            return .invalidProto
        }
        sendUpgradeResponse()
        return .noError
    }
    
    fileprivate func handleUpgradeResponse() -> KMError {
        if !httpParser.isUpgradeTo(proto: "h2c") {
            setState(.error)
            onConnectError(.invalidProto)
            return .invalidProto
        }
        sendPreface()
        return .noError
    }
    
    func onError(err: KMError) {
        infoTrace("H2Connection.onError, err=\(err)")
        setState(.error)
        cleanup()
        cbError?(err.rawValue)
    }
    
    fileprivate func onConnectError(_ err: KMError) {
        setState(.error)
        cleanup()
        notifyListeners(err)
    }
    
    fileprivate func onStateOpen() {
        infoTrace("H2Connection.onStateOpen")
        setState(.open)
        if !isServer {
            notifyListeners(.noError)
        }
    }
    
    fileprivate func notifyListeners(_ err: KMError) {
        let listeners = connectListeners
        connectListeners = [:]
        for kv in listeners {
            kv.value(err)
        }
    }
    
    fileprivate func removeSelf() {
        if !connKey.isEmpty {
            let connMgr = H2ConnectionMgr.getRequestConnMgr(sslEnabled())
            connMgr.removeConnection(connKey)
        }
    }
}

let LOCAL_CONN_INITIAL_WINDOW_SIZE = 20*1024*1024
let LOCAL_STREAM_INITIAL_WINDOW_SIZE = 6*1024*1024
let kClientConnectionPreface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
