# Nutil
Network protocols implementation in swift

## Implemented: TCP/UDP/HTTP/HTTP2/WebSocket

## SSL/TLS
```
certificates location is by default in /path-to-your-excutable/cert.

copy all CA certificates used to cert/ca.pem
copy your server certificate to cert/server.pem
copy your server private key to cert/server.key
```

## Simple examples
Please refer to project NutilSampleOSX for more examples

### WebSocket
```
import Nutil

let ws = NutilFactory.createWebSocket()
ws.onData { (data, len, isText, fin) in
    print("WebSocket.onData, len=\(len), fin=\(fin)")
    ws.close()
}
.onError { err in
    print("WebSocket.onError, err=\(err)")
}
let ret = ws.connect("wss://127.0.0.1:8443") { err in
    print("WebSocket.onConnect, err=\(err)")
    let buf = Array<UInt8>(repeating: 64, count: 16*1024)
    let ret = ws.sendData(buf, buf.count, false, true)
}
```
### HTTP request
```
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
_ = req.sendRequest("GET", "https://www.google.com")
```


