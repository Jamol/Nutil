//
//  UnixBridge.c
//  RemoteKit
//
//  Created by Jamol Bao on 8/12/15.
//  Copyright (c) 2015 jamol. All rights reserved.
//

#include <stdio.h>
#include <thread>
#include <mutex>

#include <openssl/crypto.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>

#if defined(WIN32) || defined(_WIN32) || defined(__WIN32__) || defined(_WIN64) || defined(__CYGWIN__)
# define getCurrentThreadId() GetCurrentThreadId()
#elif defined(macintosh) || defined(__APPLE__) || defined(__APPLE_CC__)
# define getCurrentThreadId() pthread_mach_thread_np(pthread_self())
#else
# define getCurrentThreadId() pthread_self()
#endif

extern "C" long _SSL_CTX_set_tlsext_servername_callback(SSL_CTX *ctx, int (*cb)(SSL *, int *, void *))
{
    return SSL_CTX_set_tlsext_servername_callback(ctx, cb);
}

static std::mutex* ssl_locks_ = nullptr;
unsigned long threadIdCallback(void)
{
#if 0
    unsigned long ret = 0;
    std::thread::id thread_id = std::this_thread::get_id();
    std::stringstream ss;
    ss << thread_id;
    ss >> ret;
    return ret;
#else
    return getCurrentThreadId();
#endif
}

void lockingCallback(int mode, int n, const char *file, int line)
{
    (void)(file);
    (void)(line);
    
    if (mode & CRYPTO_LOCK) {
        ssl_locks_[n].lock();
    } else {
        ssl_locks_[n].unlock();
    }
}

extern "C" void initSslThreading()
{
    if (CRYPTO_get_locking_callback() == NULL) {
        ssl_locks_ = new std::mutex[CRYPTO_num_locks()];
        CRYPTO_set_id_callback(threadIdCallback);
        CRYPTO_set_locking_callback(lockingCallback);
    }
}

extern "C" void deinitSslThreading()
{
    if (ssl_locks_) {
        CRYPTO_set_id_callback(nullptr);
        CRYPTO_set_locking_callback(nullptr);
        delete [] ssl_locks_;
        ssl_locks_ = nullptr;
    }
}
