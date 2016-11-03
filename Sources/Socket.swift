//
//  Socket.swift
//  Nutil
//
//  Created by Jamol Bao on 11/2/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//

import Foundation

public class Socket
{
    internal var fd: Int32? = nil
    fileprivate var queue: DispatchQueue? = nil
    fileprivate var readSource: DispatchSourceRead? = nil
    fileprivate var writeSource: DispatchSourceWrite? = nil
    fileprivate var writeSuspended = true
    
    init (dq: DispatchQueue?) {
        self.queue = dq
    }
    
    deinit {
        infoTrace("Socket.deinit, fd=\(fd)")
        cleanup()
    }
    
    internal func cleanup() {
        if let fd = self.fd {
            infoTrace("Socket.cleanup, close fd: \(fd)")
            let _ = Darwin.close(fd)
            self.fd = nil
        }
        if let rsource = readSource {
            rsource.cancel()
            readSource = nil
        }
        if let wsource = writeSource {
            wsource.cancel()
            if writeSuspended {
                wsource.resume()
            }
            writeSource = nil
        }
        queue = nil
    }
    
    internal func initWithFd(_ fd: Int32) -> Bool {
        self.fd = fd
        setNonblocking(fd)
        if !initQueue() {
            return false
        }
        if !initDispatchSource(fd: fd) {
            return false
        }
        return true
    }
    
    private func initQueue() -> Bool {
        if queue == nil {
            queue = DispatchQueue(label: "com.jamol.Socket")
            if queue == nil {
                errTrace("failed to create dispatch queue")
                return false
            }
        }
        queue!.setSpecific(key: kSocketQueueKey, value: kSocketQueueVal)
        return true
    }
    
    private func initDispatchSource(fd: Int32) -> Bool {
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        if let rsource = readSource {
            rsource.setEventHandler {
                self.processRead(fd: fd, rsource: rsource)
            }
            rsource.setCancelHandler {
                if self.fd != -1 {
                    //Darwin.close(fd)
                }
            }
            rsource.resume()
        } else {
            errTrace("failed to create read dispatch source")
            return false
        }
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        if let wsource = writeSource {
            wsource.setEventHandler {
                self.processWrite(fd: fd, wsource: wsource)
            }
            wsource.setCancelHandler {
                if self.fd != -1 {
                    //Darwin.close(fd)
                }
            }
            wsource.resume()
            writeSuspended = false
        } else {
            errTrace("failed to create write dispatch source")
            return false
        }
        return true
    }
    
    internal func processRead(fd: Int32, rsource: DispatchSourceRead) {
        fatalError("Must Override processRead")
    }
    
    internal func processWrite(fd: Int32, wsource: DispatchSourceWrite) {
        fatalError("Must Override processWrite")
    }
    
    public func close() {
        sync {
            self.cleanup()
        }
    }
    
    fileprivate func isInQueue() -> Bool {
        return DispatchQueue.getSpecific(key: kSocketQueueKey) == kSocketQueueVal
    }
    
    internal func wouldBlock(_ err: Int32) -> Bool {
        return err == EWOULDBLOCK || err == EINPROGRESS || err == EAGAIN
    }
    
    internal func resumeOnWrite() {
        if writeSuspended {
            writeSource!.resume()
            writeSuspended = false
        }
    }
    
    internal func suspendOnWrite() {
        if !writeSuspended {
            writeSource!.suspend()
            writeSuspended = true
        }
    }
}

extension Socket {
    public func sync(_ block: ((Void) -> Void)) {
        if let q = queue {
            if isInQueue() { // avoid deadlock
                block()
            } else {
                q.sync(execute: block)
            }
        } else {
            block()
        }
    }
    
    public func async(_ block: @escaping ((Void) -> Void)) {
        if let q = queue {
            q.async(execute: block)
        }
    }
}

private var kSocketQueueKey = DispatchSpecificKey<Int>()
private var kSocketQueueVal = 201
