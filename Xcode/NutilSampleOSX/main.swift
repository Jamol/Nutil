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
    let d = [UInt8](repeating: 0, count: 4096)
    let ret = udp.read(d)
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

#if true
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
    _ = req.sendRequest(method: "get", url: "https://www.google.com")
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
    let ret = ws.connect(ws_url: "wss://127.0.0.1:8443") { err in
        print("WebSocket.onConnect, err=\(err)")
        let buf = Array<UInt8>(repeating: 64, count: 16*1024)
        let ret = ws.sendData(buf, buf.count)
    }
#endif

RunLoop.main.run()
