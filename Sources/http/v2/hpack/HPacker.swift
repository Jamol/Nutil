//
//  HPacker.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

typealias NameValueArray = [(name: String, value: String)]
class HPacker {
    let table = HPackTable()
    var updateTableSize = true
    
    enum IndexingType {
        case none, name, all
    }
    
    func getIndexingType(_ name: String, _ value: String) -> IndexingType {
        if name == "cookie" || name == ":authority" || name == "user-agent" || name == "pragma" {
            return .all
        }
        return .none
    }
    
    func setMaxTableSize(_ maxSize: Int) {
        table.setMaxSize(maxSize)
    }
    
    func encodeSizeUpdate(_ sz: Int, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var ptr = buf
        let end = buf + len
        ptr[0] = 0x20
        let ret = encodeInteger(5, UInt64(sz), ptr, end - ptr)
        if ret <= 0 {
            return -1
        }
        ptr += ret
        return ptr - buf
    }
    
    func encodeHeader(_ name: String, _ value: String, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        var ptr = buf
        let end = buf + len
        var valueIndexed = false
        var index = 0
        (index, valueIndexed) = table.getIndex(name, value)
        var addToTable = false
        if index != -1 {
            var N: UInt8 = 0
            if valueIndexed { // name and value indexed
                ptr[0] = 0x80
                N = 7
            } else { // name indexed
                let idxType = getIndexingType(name, value)
                if idxType == .all {
                    ptr[0] = 0x40
                    N = 6
                    addToTable = true
                } else {
                    ptr[0] = 0x10
                    N = 4
                }
            }
            // encode prefix Bits
            var ret = encodeInteger(N, UInt64(index), ptr, end - ptr)
            if ret <= 0 {
                return -1
            }
            ptr += ret
            if !valueIndexed {
                ret = encodeString(value, ptr, end - ptr)
                if (ret <= 0) {
                    return -1
                }
                ptr += ret
            }
        } else {
            let idxType = getIndexingType(name, value)
            if idxType == .all {
                ptr[0] = 0x40
                ptr += 1
                addToTable = true
            } else {
                ptr[0] = 0x10
                ptr += 1
            }
            var ret = encodeString(name, ptr, end - ptr)
            if ret <= 0 {
                return -1
            }
            ptr += ret
            ret = encodeString(value, ptr, end - ptr)
            if ret <= 0 {
                return -1
            }
            ptr += ret
        }
        if (addToTable) {
            _ = table.addHeader(name, value)
        }
        
        return ptr - buf
    }
    
    func encode(_ headers: NameValueArray, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
        table.isEncoder = true
        var ptr = buf
        let end = buf + len
        
        if updateTableSize {
            updateTableSize = false
            let ret = encodeSizeUpdate(table.getLimitSize(), ptr, end - ptr)
            if ret <= 0 {
                return -1
            }
            ptr += ret
        }
        for hdr in headers {
            let ret = encodeHeader(hdr.name, hdr.value, ptr, end - ptr)
            if ret <= 0 {
                return -1
            }
            ptr += ret
        }
        return ptr - buf
    }
    
    func decode(_ buf: UnsafePointer<UInt8>, _ len: Int) -> (Int, NameValueArray) {
        table.isEncoder = false
        var ptr = buf
        let end = buf + len
        
        var headers: NameValueArray = []
        
        while ptr < end {
            var name: String?
            var value: String?
            var type: PrefixType = .indexedHeader
            var I: UInt64 = 0
            var ret: Int = -1
            (ret, type, I) = decodePrefix(ptr, end - ptr)
            if ret <= 0 {
                return (-1, [])
            }
            ptr += ret
            if type == .indexedHeader {
                name = table.getIndexedName(Int(I))
                if name == nil {
                    return (-1, [])
                }
                value = table.getIndexedValue(Int(I))
                if value == nil {
                    return (-1, [])
                }
            } else if type == .literalHeaderWithIndexing || type == .literalHeaderWithoutIndexing {
                if I == 0 {
                    (ret, name) = decodeString(ptr, end - ptr)
                    if ret <= 0 {
                        return (-1, [])
                    }
                    ptr += ret
                } else {
                    name = table.getIndexedName(Int(I))
                    if name == nil {
                        return (-1, [])
                    }
                }
                (ret, value) = decodeString(ptr, end - ptr)
                if ret <= 0 {
                    return (-1, [])
                }
                ptr += ret
                if type == .literalHeaderWithIndexing {
                    _ = table.addHeader(name!, value!)
                }
            } else if type == .tableSizeUpdate {
                if I > UInt64(table.getMaxSize()) {
                    return (-1, [])
                }
                table.updateLimitSize(Int(I))
                continue
            }
            headers.append((name!, value!))
        }
        return (len, headers)
    }
}

func huffDecodeBits(_ dst: UnsafeMutablePointer<UInt8>, _ bits: UInt8, _ state: UInt8) -> (ptr: UnsafeMutablePointer<UInt8>?, state: UInt8, ending: Bool) {
    let entry = huff_decode_table[Int(state)][Int(bits)]
    if (entry.flags & nghttp2_huff_decode_flag.NGHTTP2_HUFF_FAIL.rawValue) != 0 {
        return (nil, state, false)
    }
    var pos: Int = 0
    if (entry.flags & nghttp2_huff_decode_flag.NGHTTP2_HUFF_SYM.rawValue) != 0 {
        dst[0] = entry.sym
        pos = 1
    }
    let ending = (entry.flags & nghttp2_huff_decode_flag.NGHTTP2_HUFF_ACCEPTED.rawValue) != 0
    return (dst + pos, entry.state, ending)
}

func huffDecode(_ src: UnsafePointer<UInt8>, _ len: Int) -> (ret: Int, str: String?) {
    var state: UInt8 = 0
    var ending = false
    var src = src
    let src_end = src + len
    
    var sbuf = Array<UInt8>(repeating: 0, count: 2*len)
    return sbuf.withUnsafeMutableBufferPointer {
        let base = $0.baseAddress!
        var ptr = base
        while src != src_end {
            var ret = huffDecodeBits(ptr, src[0]>>4, state)
            if ret.ptr == nil {
                return (-1, nil)
            }
            ptr = ret.ptr!
            state = ret.state
            ending = ret.ending
            
            ret = huffDecodeBits(ptr, src[0]&0x0F, state)
            if ret.ptr == nil {
                return (-1, nil)
            }
            ptr = ret.ptr!
            state = ret.state
            ending = ret.ending
            src += 1
        }
        if !ending {
            return (-1, nil)
        }
        let slen = ptr - base
        //let str = String(bytesNoCopy: base, length: slen, encoding: .ascii, freeWhenDone: false)
        let data = Data(bytes: base, count: slen)
        let str = String(data: data, encoding: .ascii)
        return (slen, str)
    }
}

func huffEncode(_ str: String, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
    return huffEncode(UnsafePointer<UInt8>(str), str.utf8.count, buf, len)
}

func huffEncode(_ src: UnsafePointer<UInt8>, _ slen: Int, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
    var ptr = buf
    var src = src
    let src_end = src + slen
    
    var current: UInt64 = 0
    var n: UInt32 = 0
    
    while src != src_end {
        let sym = huff_sym_table[Int(src[0])]
        src += 1
        let code = sym.code
        let nbits = sym.nbits
        current <<= UInt64(nbits)
        current |= UInt64(code)
        n += nbits
        
        while n >= 8 {
            n -= 8
            ptr[0] = UInt8((current >> UInt64(n)) & 0xFF)
            ptr += 1
        }
    }
    
    if n > 0 {
        current <<= UInt64(8 - n)
        current |= UInt64(0xFF >> n)
        ptr[0] = UInt8(current & 0xFF)
        ptr += 1
    }
    
    return ptr - buf
}

func huffEncodeLength(_ str: String) -> Int {
    var rlen = 0
    _ = str.utf8.map { rlen += Int(huff_sym_table[Int(UInt8($0))].nbits) }
    return (rlen + 7) >> 3
}

func encodeInteger(_ N: UInt8, _ I: UInt64, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
    var ptr = buf
    let end = buf + len
    var I = I
    if len == 0 {
        return -1
    }
    let NF: UInt8 = (1 << N) - 1
    if I < UInt64(NF) {
        ptr[0] &= NF ^ 0xFF
        ptr[0] |= UInt8(I)
        return 1
    }
    ptr[0] |= NF
    ptr += 1
    I -= UInt64(NF)
    while ptr < end && I >= 128 {
        ptr[0] = UInt8(I % 128 + 128)
        ptr += 1
        I /= 128
    }
    if ptr == end {
        return -1
    }
    ptr[0] = UInt8(I)
    ptr += 1
    
    return ptr - buf
}

func encodeString(_ str: String, _ buf: UnsafeMutablePointer<UInt8>, _ len: Int) -> Int {
    var ptr = buf
    let end = buf + len
    
    let slen = str.utf8.count
    let hlen = huffEncodeLength(str)
    if hlen < slen {
        ptr[0] = 0x80
        var ret = encodeInteger(7, UInt64(hlen), ptr, end - ptr)
        if ret <= 0 {
            return -1
        }
        ptr += ret
        ret = huffEncode(str, ptr, end - ptr)
        if ret < 0 {
            return -1
        }
        ptr += ret
    } else {
        ptr[0] = 0
        let ret = encodeInteger(7, UInt64(slen), ptr, end - ptr)
        if ret <= 0 {
            return -1
        }
        ptr += ret
        if end - ptr < slen {
            return -1
        }
        memcpy(ptr, str, slen)
        ptr += slen
    }
    
    return ptr - buf
}

func decodeInteger(_ N: UInt8, _ src: UnsafePointer<UInt8>, _ len: Int) -> (ret: Int, I: UInt64) {
    if N > 8 {
        return (-1, 0)
    }
    var ptr = src
    let end = src + len
    if len == 0 {
        return (-1, 0)
    }
    var I: UInt64 = 0
    let NF: UInt8 = (1 << N) - 1
    let prefix: UInt8 = ptr[0] & NF
    ptr += 1
    if prefix < NF {
        I = UInt64(prefix)
        return (1, I)
    }
    if ptr == end {
        return (-1, 0)
    }
    var m = 0
    var u64 = UInt64(prefix)
    var b: UInt8 = 0
    repeat {
        b = ptr[0]
        ptr += 1
        u64 += UInt64(Int(b & 127) * Int(pow(Double(2), Double(m))))
        m += 7
    } while ptr < end && (b & 128) != 0
    if ptr == end && (b & 128) != 0 {
        return (-1, 0)
    }
    I = u64
    
    return (ptr - src, I)
}

func decodeString(_ src: UnsafePointer<UInt8>, _ len: Int) -> (ret: Int, str: String?) {
    var ptr = src
    let end = src + len
    if len == 0 {
        return (-1, nil)
    }
    let H = (ptr[0] & 0x80) != 0
    var slen = UInt64(0)
    let ret = decodeInteger(7, ptr, end - ptr)
    if ret.ret <= 0 {
        return (-1, nil)
    }
    slen = ret.I
    ptr += ret.ret
    if slen > UInt64(end - ptr) {
        return (-1, nil)
    }
    var str: String?
    if H {
        let ret = huffDecode(ptr, Int(slen))
        if ret.ret < 0 {
            return (-1, nil)
        }
        str = ret.str
    } else {
        //let p = UnsafeMutablePointer<UInt8>(mutating: ptr)
        //str = String(bytesNoCopy: p, length: Int(slen), encoding: .ascii, freeWhenDone: false)!
        let data = Data(bytes: ptr, count: Int(slen))
        str = String(data: data, encoding: .ascii)
    }
    ptr += Int(slen)
    
    return (ptr - src, str)
}

enum PrefixType {
    case indexedHeader
    case literalHeaderWithIndexing
    case literalHeaderWithoutIndexing
    case tableSizeUpdate
}

func decodePrefix(_ src: UnsafePointer<UInt8>, _ len: Int) -> (ret: Int, type: PrefixType, I: UInt64) {
    var ptr = src
    let end = src + len
    if len == 0 {
        return (-1, .indexedHeader, 0)
    }
    var N: UInt8 = 0
    var type = PrefixType.indexedHeader
    if (ptr[0] & 0x80) != 0 {
        N = 7
        type = .indexedHeader
    } else if (ptr[0] & 0x40) != 0 {
        N = 6
        type = .literalHeaderWithIndexing
    } else if (ptr[0] & 0x20) != 0 {
        N = 5
        type = .tableSizeUpdate
    } else {
        N = 4
        type = .literalHeaderWithoutIndexing
    }
    let ret = decodeInteger(N, ptr, end - ptr)
    if ret.ret <= 0 {
        return (-1, .indexedHeader, 0)
    }
    ptr += ret.ret
    return (ptr - src, type, ret.I)
}
