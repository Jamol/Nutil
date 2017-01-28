//
//  H2Utils.swift
//  Nutil
//
//  Created by Jamol Bao on 12/24/16.
//
//

import Foundation

typealias KeyValuePair = (name: String, value: String)

func encode_u32(_ dst: UnsafeMutablePointer<UInt8>, _ u32: UInt32) {
    dst[0] = UInt8((u32 >> 24) & 0xFF)
    dst[1] = UInt8((u32 >> 16) & 0xFF)
    dst[2] = UInt8((u32 >> 8) & 0xFF)
    dst[3] = UInt8(u32 & 0xFF)
}

func decode_u32(_ src: UnsafePointer<UInt8>) -> UInt32 {
    var u32: UInt32 = 0;
    u32 |= UInt32(src[0]) << 24
    u32 |= UInt32(src[1]) << 16
    u32 |= UInt32(src[2]) << 8
    u32 |= UInt32(src[3])
    return u32
}

func encode_u24(_ dst: UnsafeMutablePointer<UInt8>, _ u24: UInt32) {
    dst[0] = UInt8((u24 >> 16) & 0xFF)
    dst[1] = UInt8((u24 >> 8) & 0xFF)
    dst[2] = UInt8(u24 & 0xFF)
}

func decode_u24(_ src: UnsafePointer<UInt8>) -> UInt32 {
    var u24: UInt32 = 0;
    u24 |= UInt32(src[0]) << 16
    u24 |= UInt32(src[1]) << 8
    u24 |= UInt32(src[2])
    return u24
}

func encode_u16(_ dst: UnsafeMutablePointer<UInt8>, _ u16: UInt16) {
    dst[0] = UInt8((u16 >> 8) & 0xFF)
    dst[1] = UInt8(u16 & 0xFF)
}

func decode_u16(_ src: UnsafePointer<UInt8>) -> UInt16 {
    var u16: UInt16 = 0;
    u16 |= UInt16(src[0]) << 8
    u16 |= UInt16(src[1])
    return u16
}

func isPromisedStream(_ streamId: UInt32) -> Bool {
    return (streamId & 1) == 0
}
