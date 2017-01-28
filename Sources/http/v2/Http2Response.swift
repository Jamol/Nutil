//
//  Http2Response.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class Http2Response : HttpHeader {
    fileprivate var stream: H2Stream?
    
    func attachStream(_ conn: H2Connection, _ streamId: UInt32) -> KMError {
        stream = conn.getStream(streamId)
        if stream == nil {
            return .invalidParam
        }
        
        return .noError
    }
}
