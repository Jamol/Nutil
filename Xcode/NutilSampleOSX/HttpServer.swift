//
//  HttpServer.swift
//  Nutil
//
//  Created by Jamol Bao on 12/20/16.
//
//

import Foundation
import Nutil

fileprivate var wwwPath = ""
let kPathSeparator = "/"

class HttpTest {
    fileprivate var response: HttpResponse!
    fileprivate var isOptions = false
    fileprivate var sendFile = false
    fileprivate var bytesReceived = 0
    fileprivate var filePath = ""
    
    func setFd(fd: SOCKET_FD, ver: String) {
        response = NutilFactory.createResponse(version: ver)
        response
            .onData { (data: UnsafeMutableRawPointer, len: Int) in
                self.bytesReceived += len
                print("data received, len=\(len), total=\(self.bytesReceived)")
            }
            .onHeaderComplete {
                print("header completed, method=\(self.response.getMethod())")
            }
            .onRequestComplete {
                print("request completed")
                self.handleRequest()
            }
            .onResponseComplete {
                print("response completed")
                self.response.reset() // prepare for reusing
            }
            .onError { err in
                print("onError, err=\(err)")
            }
            .onSend {
                if self.sendFile {
                    self.sendTestFile()
                } else {
                    self.sendTestData()
                }
            }
        _ = response.attachFd(fd, nil, 0)
    }
    
    func handleRequest() {
        if response.getMethod().caseInsensitiveCompare("OPTIONS") == .orderedSame {
            isOptions = true
            response.addHeader("Content-Length", 0)
        }
        var str = response.getHeader("Access-Control-Request-Headers")
        if let acrh = str {
            response.addHeader("Access-Control-Allow-Headers", acrh)
        }
        str = response.getHeader("Access-Control-Request-Method")
        if let acrm = str {
            response.addHeader("Access-Control-Allow-Methods", acrm)
        }
        
        var statusCode = 200
        var desc = "OK"
        
        if !isOptions {
            filePath = wwwPath
            if response.getPath().compare("/") == .orderedSame {
                filePath += kPathSeparator + "index.html"
                sendFile = true
            } else if response.getPath().compare("/testdata") == .orderedSame {
                sendFile = false
                var contentLength = 256*1024*1024
                let ua = response.getHeader("User-Agent")
                if let ua = ua, ua.compare("kuma") != .orderedSame {
                    contentLength = 128*1024*1024
                }
                response.addHeader("Content-Length", contentLength)
            } else {
                filePath += response.getPath()
                sendFile = true
            }
            
            if sendFile {
                let mgr = FileManager.default
                if mgr.fileExists(atPath: filePath) {
                    let ext = (filePath as NSString).pathExtension
                    response.addHeader("Content-Type", getMime(ext: ext))
                } else {
                    statusCode = 404
                    desc = "Not Found"
                    response.addHeader("Content-Type", "text/html")
                }
                response.addHeader("Transfer-Encoding", "chunked")
            }
        }
        
        _ = response.sendResponse(statusCode, desc)
    }
    
    func sendTestFile() {
        let fp1 = fopen(filePath, "rb")
        guard let fp = fp1 else {
            let str = "<html><body>404 Not Found!</body></html>"
            _ = response.sendString(str)
            _ = response.sendData(nil, 0)
            return
        }
        
        var buf = [UInt8](repeating: 0, count: 4096)
        let blen = buf.count
        let nread = buf.withUnsafeMutableBufferPointer {
            return fread($0.baseAddress, 1, blen, fp)
        }
        fclose(fp)
        if nread > 0 {
            let ret = response.sendData(buf, nread)
            if ret < 0 {
                return
            } else if ret < nread {
                // should buffer remain data
                return
            } else {
                _ = response.sendData(nil, 0)
            }
        } else {
            _ = response.sendData(nil, 0)
        }
    }
    
    func sendTestData() {
        if isOptions {
            return
        }
        
        let buf = Array<UInt8>(repeating: 64, count: 16*1024)
        while true {
            let ret = response.sendData(buf, buf.count)
            if ret < 0 {
                break
            } else if ret < buf.count {
                // should buffer remain data
                break
            }
        }
    }
}

class HttpServer {
    
    fileprivate var acceptor = Acceptor()
    
    init() {
        let execPath = Bundle.main.executablePath!
        let path = (execPath as NSString).deletingLastPathComponent
        wwwPath = path + kPathSeparator + "www"
        acceptor.onAccept(onAccept)
    }
    
    func start(addr: String, port: Int) -> Bool {
        return acceptor.listen(addr, port)
    }
    
    func stop() {
        acceptor.stop()
    }
    
    fileprivate func onAccept(fd: SOCKET_FD, addr: String, port: Int) {
        print("HttpServer.onAccept, fd=\(fd), addr=\(addr), port=\(port)")
        let http = HttpTest()
        http.setFd(fd: fd, ver: "HTTP/1.1")
    }
}

func getMime(ext: String) -> String {
    switch ext {
    case "html", "htm":
        return "text/html"
    case "js":
        return "text/javascript"
    default:
        return "application/octet-stream"
    }
}
