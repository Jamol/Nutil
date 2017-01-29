//
//  main.swift
//  NutilSampleOSX
//
//  Created by Jamol Bao on 11/3/16.
//
//

import Foundation

import Nutil

#if false
var tcp = TcpSocket()
tcp.onConnect {
    print("Tcp.onConnect, err=\($0)\n")
}

//let ret = tcp.connect("127.0.0.1", 52328)
let ret = tcp.connect("www.google.com", 80)
#endif

#if false
var a = Acceptor()
a.onAccept { (fd, ip, port) in
    print("onAccept, fd=\(fd), ip=\(ip), port=\(port)")
}
_ = a.listen("127.0.0.1", 52328)
#endif

#if false
var udp = UdpSocket()
udp.onRead {
    var d = [UInt8](repeating: 0, count: 4096)
    let len = d.count
    let ret = d.withUnsafeMutableBufferPointer() {
        return udp.read($0.baseAddress!, len)
    }
    print("Udp.onRead, ret=\(ret)")
}
_ = udp.bind("127.0.0.1", 52328)
#endif

#if false
var ssl = SslSocket()
ssl.onConnect {
    print("Ssl.onConnect, err=\($0)\n")
}
let ret = ssl.connect("www.google.com", 443)
#endif

#if false
    let req = NutilFactory.createRequest(version: "HTTP/1.1")!
    req
        .onData { (data: UnsafeMutableRawPointer, len: Int) in
            print("data received, len=\(len)")
        }
        .onHeaderComplete {
            print("header completed")
        }
        .onRequestComplete {
            print("request completed")
        }
        .onError { err in
            print("request error, err=\(err)")
        }
    _ = req.sendRequest("GET", "https://www.google.com")
#endif

#if false
    let server = HttpServer()
    _ = server.start(addr: "0.0.0.0", port: 8443)
#endif

#if false
    let ws = NutilFactory.createWebSocket()
    ws.onData { (data, len) in
        print("WebSocket.onData, len=\(len)")
    }
    .onError { err in
        print("WebSocket.onError, err=\(err)")
    }
    let ret = ws.connect("wss://127.0.0.1:8443") { err in
        print("WebSocket.onConnect, err=\(err)")
        let buf = Array<UInt8>(repeating: 64, count: 16*1024)
        let ret = ws.sendData(buf, buf.count)
    }
#endif

#if true
    var totalBytesReceived = 0
    let req = NutilFactory.createRequest(version: "HTTP/2.0")!
    req
    .onData { (data: UnsafeMutableRawPointer, len: Int) in
        totalBytesReceived += len
        print("data received, len=\(len), total=\(totalBytesReceived)")
    }
    .onHeaderComplete {
        print("header completed")
    }
    .onRequestComplete {
        print("request completed")
    }
    .onError { err in
        print("request error, err=\(err)")
    }
    req.addHeader("user-agent", "kuma 1.0")
    _ = req.sendRequest("GET", "https://0.0.0.0:8443/testdata")
    //_ = req.sendRequest("GET", "https://www.google.com")
#endif

RunLoop.main.run()
