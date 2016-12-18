//
//  Http1xResponse.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/16.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

public class Http1xResponse : TcpConnection {
    
    fileprivate let parser = HttpParser()
    
    override func handleInputData(_ data: UnsafeMutablePointer<UInt8>, _ len: Int) -> Bool {
        let ret = parser.parse(data: data, len: len)
        if ret != len {
            warnTrace("handleInputData, ret=\(ret), len=\(len)")
        }
        return true
    }
    
    override func handleOnSend() {
        
    }
    
    override func handleOnError(err: KMError) {
        infoTrace("handleOnError, err=\(err)")
        onError()
    }
    
    func onError() {
        
    }
}
