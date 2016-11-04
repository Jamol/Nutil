//
//  main.swift
//  NutilSampleOSX
//
//  Created by Jamol Bao on 11/3/16.
//
//

import Foundation

import Nutil

class TcpSocketDelegate : TcpDelegate {
    public func onConnect(_ err: Int) {
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


class AcceptorDelegate : AcceptDelegate {
    func onAccept(_ fd: Int32, _ ip: String, _ port: Int) {
        print("onAccept, fd=\(fd), ip=\(ip), port=\(port)")
    }
}
let ad = AcceptorDelegate()
var a = Acceptor()
a.delegate = ad
_ = a.listen("127.0.0.1", 52328)


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

RunLoop.main.run()
