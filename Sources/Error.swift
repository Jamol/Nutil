//
//  Utils.swift
//  Nutil
//
//  Created by Jamol Bao on 1/18/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

public enum NUError: Error, CustomStringConvertible {
    case success
    case socket(code: Int, description: String)
    case ssl(code: Int, description: String)
    
    public var code: Int {
        switch self {
        case .success:
            return 0
        case .socket(let (code, _)):
            return Int(code)
        case .ssl(let (code, _)):
            return Int(code)
        }
    }
    
    public var description: String {
        switch self {
        case .success:
            return "success"
        case .socket(let (_, desc)):
            return desc
        case .ssl(let (_, desc)):
            return desc
        }
    }
}

public enum KMError : Int {
    case noError
    case failed
    case invalidState
    case invalidParam
    case invalidProto
    case alreadyExist
    case again
    case sockError
    case pollError
    case protoError
    case sslError
    case bufferTooSmall
    case unsupport
}
