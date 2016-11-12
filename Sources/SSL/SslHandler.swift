//
//  SslSocket.swift
//  Nutil
//
//  Created by Jamol Bao on 11/4/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

enum SslRole {
    case client
    case server
}

class SslHandler {
    var ssl: UnsafeMutablePointer<SSL>!
    var fd: SOCKET_FD = kInvalidSocket
    var isServer = false
    
    enum SslState {
        case none
        case handshake
        case success
        case error
    }
    
    fileprivate var sslState = SslState.none
    
    init () {
        _ = OpenSslLib.initSslOnce
    }
    
    fileprivate func setState(_ state: SslState) {
        sslState = state
    }
    
    func getState() -> SslState {
        return sslState
    }
    
    func setAlpnProtocols(alpn: AlpnProtos) {
        if (SSL_set_alpn_protos(ssl, alpn, UInt32(alpn.count)) == 1) {
            return; // success
        }
    }
    
    func setServerName(name: String) {
        if (SSL_set_tlsext_host_name(ssl, UnsafeMutablePointer<Int8>(mutating: name)) == 1) {
            return ; // success
        }
    }
    
    func attachFd(fd: SOCKET_FD, role: SslRole) throws {
        cleanup()
        isServer =  role == .server
        
        var ctx: UnsafeMutablePointer<SSL_CTX>!
        if isServer {
            ctx = defaultServerContext()
        } else {
            ctx = defaultClientContext()
        }
        ssl = SSL_new(ctx)
        guard ssl != nil else {
            throw NUError.ssl(code: Int(ERR_get_error()), description: "SSL_new")
        }
        //SSL_set_mode(ssl, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
        //SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE);
        let ret = SSL_set_fd(ssl, fd)
        if ret == 0 {
            SSL_free(ssl)
            ssl = nil
            throw NUError.ssl(code: Int(ERR_get_error()), description: "SSL_set_fd")
        }
        self.fd = fd
    }
    
    func attachSsl(fd: SOCKET_FD, ssl: UnsafeMutablePointer<SSL>?) {
        cleanup()
        self.ssl = ssl
        self.fd = fd
        if ssl != nil {
            setState(.success);
        }
    }
    
    func detachSsl(ssl: UnsafeMutablePointer<UnsafeMutablePointer<SSL>?>) {
        ssl.pointee = self.ssl
        self.ssl = nil
        self.fd = kInvalidSocket
    }
    
    func sslConnect() -> SslState {
        guard let ssl = ssl else {
            errTrace("sslConnect, ssl is nil")
            return .error
        }
        
        let ret = SSL_connect(ssl)
        let ssl_err = SSL_get_error (ssl, ret)
        switch (ssl_err)
        {
        case SSL_ERROR_NONE:
            return .success;
            
        case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
            return .handshake;
            
        default:
            printSslError("sslConnect", ret, ssl_err)
            SSL_free(ssl);
            self.ssl = nil;
            return .error;
        }
    }
    
    func sslAccept() -> SslState {
        guard let ssl = ssl else {
            errTrace("sslAccept, ssl is nil")
            return .error
        }
        
        let ret = SSL_accept(ssl);
        let ssl_err = SSL_get_error(ssl, ret);
        switch (ssl_err)
        {
        case SSL_ERROR_NONE:
            return .success
            
        case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
            return .handshake
            
        default:
            printSslError("sslAccept", ret, ssl_err)
            SSL_free(ssl);
            self.ssl = nil
            return .error
        }
    }
    
    func send(data: UnsafeRawPointer, len: Int) -> Int {
        guard let ssl = ssl else {
            errTrace("send, ssl is nil")
            return -1
        }
        
        ERR_clear_error()
        var offset = 0
        
        // loop send until read/write want since we enabled partial write
        while (offset < len) {
            var ret = SSL_write(ssl, data + offset, Int32(len - offset));
            let ssl_err = SSL_get_error(ssl, ret);
            switch (ssl_err)
            {
            case SSL_ERROR_NONE:
                break
            case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
                ret = 0
            case SSL_ERROR_SYSCALL:
                if(errno == EAGAIN || errno == EINTR) {
                    ret = 0
                } else {
                    printSslError("send", ret, ssl_err)
                    ret = -1
                }
            default:
                printSslError("send", ret, ssl_err)
                ret = -1
            }
            
            if(ret < 0) {
                cleanup();
                return Int(ret);
            }
            offset += Int(ret);
            if (ret == 0) {
                break;
            }
        }
        return offset;
    }
    
    func send(iovs: [iovec]) -> Int {
        var bytes_sent = 0;
        for iov in iovs {
            let ret = send(data: iov.iov_base, len: iov.iov_len);
            if(ret < 0) {
                return ret;
            } else {
                bytes_sent += ret;
                if(ret < iov.iov_len) {
                    break;
                }
            }
        }
        return bytes_sent;
    }
    
    func receive(data: UnsafeMutableRawPointer, len: Int) -> Int {
        guard let ssl = ssl else {
            errTrace("receive, ssl is nil")
            return -1
        }
        ERR_clear_error();
        var ret = SSL_read(ssl, data, Int32(len));
        let ssl_err = SSL_get_error(ssl, ret);
        switch (ssl_err)
        {
        case SSL_ERROR_NONE:
            break;
        case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
            ret = 0
        case SSL_ERROR_ZERO_RETURN:
            ret = -1
            infoTrace("receive, SSL_ERROR_ZERO_RETURN")
        case SSL_ERROR_SYSCALL:
            if(errno == EAGAIN || errno == EINTR) {
                ret = 0
            } else {
                printSslError("receive", ret, ssl_err)
                ret = -1
            }
        default:
            printSslError("receive", ret, ssl_err)
            ret = -1
        }
        
        if(ret < 0) {
            cleanup()
        }
        
        //infoTrace("receive, ret: \(ret));
        return Int(ret)
    }
    
    func close() {
        cleanup()
    }
    
    func doSslHandshake() -> SslState {
        var state = SslState.handshake
        if isServer {
            state = sslAccept()
        } else {
            state = sslConnect()
        }
        setState(state)
        if state == .error {
            cleanup()
        }
        return state
    }
    
    func printSslError(_ func_str: String, _ ssl_status: Int32, _ ssl_err: Int32) {
        var err_str = ""
        let err_cstr = ERR_reason_error_string(ERR_get_error());
        if let cstr = err_cstr {
            err_str = String(cString: cstr)
        }
        errTrace("\(func_str), error, fd=\(fd), ssl_status=\(ssl_status), ssl_err=\(ssl_err), os_err=\(errno), err_msg=\(err_str)")
    }
    
    func cleanup() {
        if(ssl != nil) {
            SSL_shutdown(ssl)
            SSL_free(ssl)
            ssl = nil
        }
        fd = kInvalidSocket
    }
}
