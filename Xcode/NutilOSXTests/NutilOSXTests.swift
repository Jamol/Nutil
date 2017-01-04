//
//  NutilOSXTests.swift
//  NutilOSXTests
//
//  Created by Jamol Bao on 11/3/16.
//
//

import XCTest
@testable import Nutil

class NutilOSXTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }
    
    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
    
    func testHPacker_Decode_Encode() {
        
        let hex_str = "820481634188353daded6ae43d3f877abdd07f66a281b0dae053fad0321aa49d13fda992a49685340c8a6adca7e28102e10fda9677b8d05707f6a62293a9d810020004015309ac2ca7f2c3415c1f53b0497ca589d34d1f43aeba0c41a4c7a98f33a69a3fdf9a68fa1d75d0620d263d4c79a68fbed00177febe58f9fbed00177b518b2d4b70ddf45abefb4005db901f1184ef034eff609cb60725034f48e1561c8469669f081678ae3eb3afba465f7cb234db9f4085aec1cd48ff86a8eb10649cbf"
        
        var ret: Int = -1
        var headers: NameValueArray = []
        let hp = HPacker()
        let vec = hexStringToArray(hexStr: hex_str)
        (ret, headers) = hp.decode(vec, vec.count)
        print("ret=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(193, ret)
        XCTAssertEqual(11, headers.count)
        
        var buf = Array<UInt8>(repeating: 0, count: hex_str.utf8.count)
        let hpe = HPacker()
        ret = buf.withUnsafeMutableBufferPointer {
            let ptr = $0.baseAddress!
            return hpe.encode(headers, ptr, hex_str.utf8.count)
        }
        XCTAssert(ret > 0)
        print("en_len=\(ret)")
        
        headers = []
        let hpd = HPacker()
        (ret, headers) = hpd.decode(buf, ret)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(11, headers.count)
    }
    
    func testHPacker_request_without_huffman_conding() {
        // RFC 7541 Appendix C.3
        let hex_no_huff_req1 = "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"
        let hex_no_huff_req2 = "8286 84be 5808 6e6f 2d63 6163 6865"
        let hex_no_huff_req3 = "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65"
        
        print("\ntest request without huffman coding.....................")
        var ret: Int = -1
        var headers: NameValueArray = []
        var vec = hexStringToArray(hexStr: hex_no_huff_req1)
        
        let hpd = HPacker()
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nrequest 2 ..............")
        vec = hexStringToArray(hexStr: hex_no_huff_req2)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(5, headers.count)
        
        print("\nrequest 3 ..............")
        vec = hexStringToArray(hexStr: hex_no_huff_req3)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(5, headers.count)
    }
    
    func testHPacker_request_with_huffman_conding() {
        // RFC 7541 Appendix C.4
        let hex_huff_req1 = "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"
        let hex_huff_req2 = "8286 84be 5886 a8eb 1064 9cbf"
        let hex_huff_req3 = "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"
        
        print("\ntest request with huffman coding.....................")
        var ret: Int = -1
        var headers: NameValueArray = []
        var vec = hexStringToArray(hexStr: hex_huff_req1)
        
        let hpd = HPacker()
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nrequest 2 ..............")
        vec = hexStringToArray(hexStr: hex_huff_req2)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(5, headers.count)
        
        print("\nrequest 3 ..............")
        vec = hexStringToArray(hexStr: hex_huff_req3)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(5, headers.count)
    }
    
    func testHPacker_response_without_huffman_conding() {
        // RFC 7541 Appendix C.5
        var hex_no_huff_rsp1 = ""
        hex_no_huff_rsp1 += "4803 3330 3258 0770 7269 7661 7465 611d"
        hex_no_huff_rsp1 += "4d6f 6e2c 2032 3120 4f63 7420 3230 3133"
        hex_no_huff_rsp1 += "2032 303a 3133 3a32 3120 474d 546e 1768"
        hex_no_huff_rsp1 += "7474 7073 3a2f 2f77 7777 2e65 7861 6d70"
        hex_no_huff_rsp1 += "6c65 2e63 6f6d"
        let hex_no_huff_rsp2 = "4803 3330 37c1 c0bf"
        var hex_no_huff_rsp3 = ""
        hex_no_huff_rsp3 += "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420"
        hex_no_huff_rsp3 += "3230 3133 2032 303a 3133 3a32 3220 474d"
        hex_no_huff_rsp3 += "54c0 5a04 677a 6970 7738 666f 6f3d 4153"
        hex_no_huff_rsp3 += "444a 4b48 514b 425a 584f 5157 454f 5049"
        hex_no_huff_rsp3 += "5541 5851 5745 4f49 553b 206d 6178 2d61"
        hex_no_huff_rsp3 += "6765 3d33 3630 303b 2076 6572 7369 6f6e"
        hex_no_huff_rsp3 += "3d31"
        
        print("\ntest response without huffman coding.....................")
        var ret: Int = -1
        var headers: NameValueArray = []
        var vec = hexStringToArray(hexStr: hex_no_huff_rsp1)
        
        let hpd = HPacker()
        hpd.setMaxTableSize(256)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nresponse 2 ..............")
        vec = hexStringToArray(hexStr: hex_no_huff_rsp2)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nresponse 3 ..............")
        vec = hexStringToArray(hexStr: hex_no_huff_rsp3)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(6, headers.count)
    }
    
    func testHPacker_response_with_huffman_conding() {
        // RFC 7541 Appendix C.6
        var hex_huff_rsp1 = ""
        hex_huff_rsp1 += "4882 6402 5885 aec3 771a 4b61 96d0 7abe"
        hex_huff_rsp1 += "9410 54d4 44a8 2005 9504 0b81 66e0 82a6"
        hex_huff_rsp1 += "2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8"
        hex_huff_rsp1 += "e9ae 82ae 43d3"
        let hex_huff_rsp2 = "4883 640e ffc1 c0bf"
        var hex_huff_rsp3 = ""
        hex_huff_rsp3 += "88c1 6196 d07a be94 1054 d444 a820 0595"
        hex_huff_rsp3 += "040b 8166 e084 a62d 1bff c05a 839b d9ab"
        hex_huff_rsp3 += "77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b"
        hex_huff_rsp3 += "3960 d5af 2708 7f36 72c1 ab27 0fb5 291f"
        hex_huff_rsp3 += "9587 3160 65c0 03ed 4ee5 b106 3d50 07"
        
        print("\ntest response with huffman coding.....................")
        var ret: Int = -1
        var headers: NameValueArray = []
        var vec = hexStringToArray(hexStr: hex_huff_rsp1)
        
        let hpd = HPacker()
        hpd.setMaxTableSize(256)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nresponse 2 ..............")
        vec = hexStringToArray(hexStr: hex_huff_rsp2)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(4, headers.count)
        
        print("\nresponse 3 ..............")
        vec = hexStringToArray(hexStr: hex_huff_rsp3)
        (ret, headers) = hpd.decode(vec, vec.count)
        print("de_len=\(ret)")
        for hdr in headers {
            print("\(hdr.name): \(hdr.value)")
        }
        XCTAssertEqual(6, headers.count)
    }
    
}
