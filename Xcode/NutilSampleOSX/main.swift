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
class TcpSocketDelegate : TcpDelegate {
    public func onConnect(_ err: KMError) {
        print("Tcp.onConnect, err=\(err)\n")
    }
    public func onRead() {
        
    }
    public func onWrite() {
        
    }
    public func onClose() {
        
    }
}
let tcpd = TcpSocketDelegate()
var tcp = TcpSocket()
tcp.delegate = tcpd
//let ret = tcp.connect("127.0.0.1", 52328)
let ret = tcp.connect("www.google.com", 80)
#endif

#if false
class AcceptorDelegate : AcceptDelegate {
    func onAccept(_ fd: Int32, _ ip: String, _ port: Int) {
        print("onAccept, fd=\(fd), ip=\(ip), port=\(port)")
    }
}
let ad = AcceptorDelegate()
var a = Acceptor()
a.delegate = ad
_ = a.listen("127.0.0.1", 52328)
#endif

#if false
var udp = UdpSocket()
class UdpSocketDelegate: UdpDelegate {
    func onRead() {
        let d = [UInt8](repeating: 0, count: 4096)
        let ret = udp.read(d)
        print("Udp.onRead, ret=\(ret)")
    }
    func onWrite() {
        
    }
    func onClose() {
        
    }
}
let udpd = UdpSocketDelegate()
udp.delegate = udpd
_ = udp.bind("127.0.0.1", 52328)
#endif

#if true
    class SslSocketDelegate : SslDelegate {
        public func onConnect(_ err: KMError) {
            print("Ssl.onConnect, err=\(err)\n")
        }
        public func onRead() {
            
        }
        public func onWrite() {
            
        }
        public func onClose() {
            
        }
    }
let ssld = SslSocketDelegate()
var ssl = SslSocket()
ssl.delegate = ssld
let ret = ssl.connect("www.google.com", 443)
#endif

RunLoop.main.run()
