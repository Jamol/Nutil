//
//  Mutex.swift
//  Nutil
//
//  Created by Jamol Bao on 2/7/17.
//  Copyright © 2016-2017 Jamol Bao. All rights reserved.
//

import Foundation

class Mutex {
    fileprivate var mutex = pthread_mutex_t()
    
    init() {
        pthread_mutex_init(&mutex, nil)
    }
    
    deinit {
        pthread_mutex_destroy(&mutex)
    }
    
    func lock() {
        pthread_mutex_lock(&mutex)
    }
    
    func unlock() {
        pthread_mutex_unlock(&mutex)
    }
    
    func trylock() -> Bool {
        return pthread_mutex_trylock(&mutex) == 0
    }
}
