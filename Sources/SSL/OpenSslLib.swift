//
//  OpenSslLib.swift
//  Nutil
//
//  Created by Jamol Bao on 11/4/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation
import COpenSSL

typealias AlpnProtos = [UInt8]

var alpnProtos: AlpnProtos = [2, 104, 50]

fileprivate var certsPath = "./"
fileprivate var sslCtxServer: UnsafeMutablePointer<SSL_CTX>?
fileprivate var sslCtxClient: UnsafeMutablePointer<SSL_CTX>?

class OpenSslLib {
    class var initSslOnce: Bool {
        return initOpenSslLib()
    }
}

func initOpenSslLib() -> Bool {
    if SSL_library_init() != 1 {
        return false
    }
    //OpenSSL_add_all_algorithms()
    SSL_load_error_strings()
    
    initSslThreading()
    
    // PRNG
    RAND_poll()
    while(RAND_status() == 0) {
        var rand_ret = arc4random()
        RAND_seed(&rand_ret, Int32(MemoryLayout.size(ofValue: rand_ret)))
    }
    let execPath = Bundle.main.executablePath!
    let path = (execPath as NSString).deletingLastPathComponent
    certsPath = "\(path)/cert"
    return true
}

func deinitOpenSslLib() {
    EVP_cleanup()
    CRYPTO_cleanup_all_ex_data()
    ERR_free_strings()
    deinitSslThreading()
}

func createSslContext(_ caFile: String, _ certFile: String, _ keyFile: String, _ clientMode: Bool) -> UnsafeMutablePointer<SSL_CTX>? {
    var ctx_ok = false
    var method = SSLv23_client_method();
    if !clientMode {
        method = SSLv23_server_method();
    }
    var sslContext = SSL_CTX_new(method)
    guard let ctx = sslContext else {
        return nil
    }

    repeat {
        if (SSL_CTX_set_ecdh_auto(ctx, 1) != 1) {
            warnTrace("SSL_CTX_set_ecdh_auto failed, err=\(ERR_reason_error_string(ERR_get_error()))");
        }
#if arch(arm)
        var flags = UInt(SSL_OP_ALL) | UInt(SSL_OP_NO_SSLv2) | UInt(SSL_OP_NO_SSLv3) | UInt(SSL_OP_NO_TLSv1) | UInt(SSL_OP_NO_TLSv1_1)
        flags |= UInt(SSL_OP_NO_COMPRESSION)
        _ = SSL_CTX_set_options(ctx, Int(bitPattern: flags))
#else
        var flags = SSL_OP_ALL | SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_TLSv1 | SSL_OP_NO_TLSv1_1
        flags |= SSL_OP_NO_COMPRESSION
        //let flags = UInt32(SSL_OP_ALL) | UInt32(SSL_OP_NO_COMPRESSION)
        // SSL_OP_SAFARI_ECDHE_ECDSA_BUG
        _ = SSL_CTX_set_options(ctx, flags)
#endif
        //SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION)
        _ = SSL_CTX_set_mode(ctx, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER)
        _ = SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE)
        _ = SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY)
        
        if !certFile.isEmpty && !keyFile.isEmpty {
            
            if(SSL_CTX_use_certificate_chain_file(ctx, certFile) != 1) {
                warnTrace("SSL_CTX_use_certificate_chain_file failed, file=\(certFile), err=\(ERR_reason_error_string(ERR_get_error()))")
                break
            }
            SSL_CTX_set_default_passwd_cb(ctx, passwdCallback)
            SSL_CTX_set_default_passwd_cb_userdata(ctx, ctx)
            if(SSL_CTX_use_PrivateKey_file(ctx, keyFile, SSL_FILETYPE_PEM) != 1) {
                warnTrace("SSL_CTX_use_PrivateKey_file failed, file=\(keyFile), err=\(ERR_reason_error_string(ERR_get_error()))")
                break
            }
            if(SSL_CTX_check_private_key(ctx) != 1) {
                warnTrace("SSL_CTX_check_private_key failed, err=\(ERR_reason_error_string(ERR_get_error()))");
                break
            }
        }
        
        if (!caFile.isEmpty) {
            if(SSL_CTX_load_verify_locations(ctx, caFile, nil) != 1) {
                warnTrace("SSL_CTX_load_verify_locations failed, file=\(caFile), err=\(ERR_reason_error_string(ERR_get_error()))")
                break
            }
            if(SSL_CTX_set_default_verify_paths(ctx) != 1) {
                warnTrace("SSL_CTX_set_default_verify_paths failed, err=\(ERR_reason_error_string(ERR_get_error()))")
                break
            }
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verifyCallback)
            //SSL_CTX_set_verify_depth(ctx, 4)
            //app_verify_arg arg1
            //SSL_CTX_set_cert_verify_callback(ctx, appVerifyCallback, &arg1)
        }
        SSL_CTX_set_alpn_select_cb(ctx, alpnCallback, &alpnProtos)
        _ = _SSL_CTX_set_tlsext_servername_callback(ctx, serverNameCallback)
        _ = SSL_CTX_set_tlsext_servername_arg(ctx, ctx)
        ctx_ok = true
    } while false
    if !ctx_ok {
        SSL_CTX_free(ctx)
        sslContext = nil
    }
    return sslContext
}

func defaultClientContext() -> UnsafeMutablePointer<SSL_CTX>!
{
    if sslCtxClient == nil {
        let certFile = ""
        let keyFile = ""
        let caFile = "\(certsPath)/ca.cer"
        sslCtxClient = createSslContext(caFile, certFile, keyFile, true)
    }
    return sslCtxClient
}

func defaultServerContext() -> UnsafeMutablePointer<SSL_CTX>!
{
    if sslCtxServer == nil {
        let certFile = "\(certsPath)/server.cer"
        let keyFile = "\(certsPath)/server.key"
        let caFile = ""
        sslCtxServer = createSslContext(caFile, certFile, keyFile, false)
    }
    return sslCtxServer
}

func getSslContext(_ hostName: UnsafePointer<CChar>) -> UnsafeMutablePointer<SSL_CTX>
{
    return defaultServerContext()
}

/////////////////////////////////////////////////////////////////////////////
// callbacks
func verifyCallback(_ ok: Int32, _ ctx: UnsafeMutablePointer<X509_STORE_CTX>?) -> Int32
{
    guard let ctx = ctx else {
        return ok
    }

    var ok = ok
    //SSL* ssl = static_cast<SSL*>(X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx()));
    //SSL_CTX* ssl_ctx = ::SSL_get_SSL_CTX(ssl);
    if let cert = ctx.pointee.current_cert {
        var cbuf = [Int8](repeating: 0, count: 1024)
        let s = X509_NAME_oneline(X509_get_subject_name(cert), &cbuf, Int32(cbuf.count));
        if s != nil {
            if ok != 0 {
                let str = String(cString: cbuf)
                infoTrace("verifyCallback ok, depth=\(ctx.pointee.error_depth), subject=\(str)");
                if X509_NAME_oneline(X509_get_issuer_name(cert), &cbuf, Int32(cbuf.count)) != nil {
                    let str = String(cString: cbuf)
                    infoTrace("verifyCallback, issuer=\(str)")
                }
            } else {
                errTrace("verifyCallback failed, depth=\(ctx.pointee.error_depth), err=\(ctx.pointee.error)");
            }
        }
    }
    
    if 0 == ok {
        infoTrace("verifyCallback, err=\(X509_verify_cert_error_string(Int(ctx.pointee.error)))")
        switch (ctx.pointee.error)
        {
            //case X509_V_ERR_CERT_NOT_YET_VALID:
        //case X509_V_ERR_CERT_HAS_EXPIRED:
        case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
            infoTrace("verifyCallback, ... ignored, err=\(ctx.pointee.error)")
            ok = 1
        default:
            break
        }
    }
    return ok
}

func alpnCallback(ssl: UnsafeMutablePointer<SSL>?, out: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, outlen: UnsafeMutablePointer<UInt8>?, _in: UnsafePointer<UInt8>?, inlen: UInt32, arg: UnsafeMutableRawPointer?) -> Int32
{
    guard let arg = arg else {
        return SSL_TLSEXT_ERR_OK
    }
    let alpn = arg.assumingMemoryBound(to: [UInt8].self)
    out?.withMemoryRebound(to: (UnsafeMutablePointer<UInt8>?.self), capacity: 1) {
        if (SSL_select_next_proto($0, outlen, alpn.pointee, UInt32(alpn.pointee.count), _in, inlen) != OPENSSL_NPN_NEGOTIATED) {
        }
    }
    /*if (SSL_select_next_proto(out, outlen, alpn.pointee, UInt32(alpn.pointee.count), _in, inlen) != OPENSSL_NPN_NEGOTIATED) {
     return SSL_TLSEXT_ERR_NOACK;
     }*/
    return SSL_TLSEXT_ERR_OK
}

func serverNameCallback(ssl: UnsafeMutablePointer<SSL>?, ad: UnsafeMutablePointer<Int32>?, arg: UnsafeMutableRawPointer?) -> Int32
{
    guard let ssl = ssl else {
        return SSL_TLSEXT_ERR_NOACK
    }
    let serverName = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name)
    if let sn = serverName {
        let ssl_ctx_old = arg?.assumingMemoryBound(to: SSL_CTX.self)
        let ssl_ctx_new = getSslContext(sn)
        if ssl_ctx_new != ssl_ctx_old {
            SSL_set_SSL_CTX(ssl, ssl_ctx_new)
        }
    }
    return SSL_TLSEXT_ERR_NOACK
}

func passwdCallback(buf: UnsafeMutablePointer<Int8>?, size: Int32, rwflag: Int32, userdata: UnsafeMutableRawPointer?) -> Int32
{
    //if(size < (int)strlen(pass)+1) return 0;
    return 0;
}

/////////////////////////////////////////////////////////////////////////////
//
func SSL_CTX_set_ecdh_auto(_ ctx: UnsafeMutablePointer<SSL_CTX>, _ onoff: Int) -> Int {
    return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_ECDH_AUTO, onoff, nil)
}

func SSL_CTX_set_options(_ ctx: UnsafeMutablePointer<SSL_CTX>, _ op: Int) -> Int {
    return SSL_CTX_ctrl(ctx, SSL_CTRL_OPTIONS, op, nil)
}

func SSL_CTX_set_mode(_ ctx: UnsafeMutablePointer<SSL_CTX>, _ op: Int) -> Int {
    return SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, op, nil)
}

/*func SSL_CTX_set_tlsext_servername_callback(_ ctx: UnsafeMutablePointer<SSL_CTX>, _ cb: @escaping ((UnsafeMutablePointer<SSL>?, UnsafeMutablePointer<Int32>?, UnsafeMutableRawPointer?) -> Int32)) -> Int {
    return SSL_CTX_callback_ctrl(ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, cb)
}*/

func SSL_CTX_set_tlsext_servername_arg(_ ctx: UnsafeMutablePointer<SSL_CTX>, _ arg: UnsafeMutableRawPointer?) -> Int {
    return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, arg)
}

func SSL_set_tlsext_host_name(_ ssl: UnsafeMutablePointer<SSL>, _ name: UnsafeMutablePointer<Int8>?) -> Int {
    return SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, Int(TLSEXT_NAMETYPE_host_name), name)
}
