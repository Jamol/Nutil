//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <openssl/crypto.h>
#import <openssl/ssl.h>
#import <openssl/err.h>
#import <openssl/rand.h>
#include <openssl/sha.h>

long _SSL_CTX_set_tlsext_servername_callback(SSL_CTX *ctx, int (*cb)(SSL *, int *, void *));
void initSslThreading();
void deinitSslThreading();
