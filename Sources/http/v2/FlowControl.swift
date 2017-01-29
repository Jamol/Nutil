//
//  FlowControl.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class FlowControl {
    var streamId: UInt32 = 0
    fileprivate var localWindowStep = kH2DefaultWindowSize
    fileprivate var localWindowSize_ = kH2DefaultWindowSize
    fileprivate var minLocalWindowSize = 32768
    var bytesReceived_ = 0
    
    fileprivate var remoteWindowSize_ = kH2DefaultWindowSize
    var bytesSent_ = 0
    
    var localWindowSize: Int {
        if localWindowSize_ > 0 {
            return localWindowSize_
        }
        return 0
    }
    
    var bytesSent: Int {
        get {
            return bytesSent_
        }
        
        set {
            bytesSent_ += newValue
            remoteWindowSize_ -= newValue
            if remoteWindowSize_ <= 0 && newValue + remoteWindowSize_ > 0 {
                infoTrace("FlowControl.bytesSent, streamId=\(streamId), bytesSent=\(bytesSent_), window=\(remoteWindowSize_)")
            }
        }
    }
    
    var bytesReceived: Int {
        get {
            return bytesReceived_
        }
        
        set{
            bytesReceived_ += newValue
            localWindowSize_ -= newValue
            if localWindowSize_ < minLocalWindowSize {
                let delta = localWindowStep - localWindowSize_
                localWindowSize_ += delta
                cbUpdate?(UInt32(delta) & 0xFFFFFFFF)
            }
        }
    }
    
    var remoteWindowSize: Int {
        if remoteWindowSize_ > 0 {
            return remoteWindowSize_
        }
        return 0
    }
    
    var cbUpdate: ((UInt32) -> KMError)?
    
    func setLocalWindowStep(_ windowSize: Int) {
        localWindowStep = windowSize
        if minLocalWindowSize > localWindowStep/2 {
            minLocalWindowSize = localWindowStep/2
        }
    }
    
    func setMinLocalWindowSize(_ minWindowSize: Int) {
        minLocalWindowSize = minWindowSize
        if minLocalWindowSize > localWindowStep/2 {
            minLocalWindowSize = localWindowStep/2
        }
    }
    
    func updateRemoteWindowSize(_ delta: Int) {
        remoteWindowSize_ += delta
    }
    
    func initLocalWindowSize(_ windowSize: Int) {
        localWindowSize_ = windowSize
    }
    
    func initRemoteWindowSize(_ windowSize: Int) {
        remoteWindowSize_ = windowSize
    }
    
}
