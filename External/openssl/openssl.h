#include "include/openssl/crypto.h"
#include "include/openssl/ssl.h"
#include "include/openssl/err.h"
#include "include/openssl/rand.h"
#include "include/openssl/sha.h"

long _SSL_CTX_set_tlsext_servername_callback(SSL_CTX *ctx, int (*cb)(SSL *, int *, void *));
void initSslThreading();
void deinitSslThreading();
