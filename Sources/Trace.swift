//
//  Trace.swift
//  Nutil
//
//  Created by Jamol Bao on 11/12/15.
//  Copyright © 2015 Jamol Bao. All rights reserved.
//

import Foundation

func infoTrace(_ str: String) {
    printTrace("INFO \(str)")
}

func warnTrace(_ str: String) {
    printTrace("WARN \(str)")
}

func errTrace(_ str: String) {
    printTrace("ERROR \(str)")
}

func printTrace(_ str: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let strDate = formatter.string(from: Date())
    let tid = pthread_mach_thread_np(pthread_self())
    print("\(strDate) [\(tid)] \(str)")
}
