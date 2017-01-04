//
//  HPackTable.swift
//  Nutil
//
//  Created by Jamol Bao on 12/25/16.
//  Copyright © 2016 Jamol Bao. All rights reserved.
//  Contact: jamol@live.com
//

import Foundation

class HPackTable {
    fileprivate var dynamicTable: [(name: String, value: String)] = []
    fileprivate var tableSize = 0
    fileprivate var limitSize = 4096
    fileprivate var maxSize = 4096
    var isEncoder = false
    
    fileprivate var indexSequence = 0
    fileprivate var indexMap: [String : (idxD: Int, idxS: Int)] = [:]
    
    init () {
        for i in 0..<HPACK_STATIC_TABLE_SIZE {
            let str = hpackStaticTable[i].name + hpackStaticTable[i].value
            if indexMap[str] == nil {
                indexMap[str] = (-1, i)
            }
        }
    }
    
    func getIndexedName(_ index: Int) -> String? {
        if index <= 0 {
            return nil
        }
        if index < HPACK_DYNAMIC_START_INDEX {
            return hpackStaticTable[index - 1].name
        } else if index - HPACK_DYNAMIC_START_INDEX < dynamicTable.count {
            return dynamicTable[index - HPACK_DYNAMIC_START_INDEX].name
        }
        return nil
    }
    
    func getIndexedValue(_ index: Int) -> String? {
        if index <= 0 {
            return nil
        }
        if index < HPACK_DYNAMIC_START_INDEX {
            return hpackStaticTable[index - 1].value
        } else if index - HPACK_DYNAMIC_START_INDEX < dynamicTable.count {
            return dynamicTable[index - HPACK_DYNAMIC_START_INDEX].value
        }
        return nil
    }
    
    func addHeader(_ name: String, _ value: String) -> Bool {
        let entrySize = name.utf8.count + value.utf8.count + TABLE_ENTRY_SIZE_EXTRA
        if entrySize + tableSize > limitSize {
            evictTableBySize(entrySize + tableSize - limitSize)
        }
        if entrySize > limitSize {
            return false
        }
        dynamicTable.insert((name, value), at: 0)
        tableSize += entrySize
        if isEncoder {
            indexSequence += 1
            updateIndex(name, indexSequence)
        }
        return true
    }
    
    func setMaxSize(_ sz: Int) {
        maxSize = sz
        if limitSize > maxSize {
            updateLimitSize(maxSize)
        }
    }
    
    func updateLimitSize(_ sz: Int) {
        if tableSize > sz {
            evictTableBySize(tableSize - sz)
        }
        limitSize = sz
    }
    
    func getMaxSize() -> Int {
        return maxSize
    }
    
    func getLimitSize() -> Int {
        return limitSize
    }
    
    func getTableSize() -> Int {
        return tableSize
    }
    
    fileprivate func evictTableBySize(_ sz: Int) {
        var evicted = 0
        while evicted < sz && !dynamicTable.isEmpty {
            let entry = dynamicTable[dynamicTable.count - 1];
            let entrySize = entry.name.utf8.count + entry.value.utf8.count + TABLE_ENTRY_SIZE_EXTRA;
            if tableSize > entrySize {
                tableSize -= entrySize
            } else {
                tableSize = 0
            }
            if isEncoder {
                removeIndex(entry.name);
            }
            dynamicTable.remove(at: dynamicTable.count - 1)
            evicted += entrySize;
        }
    }
    
    fileprivate func getDynamicIndex(_ idxSeq: Int) -> Int {
        if idxSeq == -1 {
            return -1
        }
        return indexSequence - idxSeq;
    }
    
    fileprivate func updateIndex(_ name: String, _ idxSeq: Int) {
        if indexMap[name] != nil {
            indexMap[name]!.idxD = idxSeq
        } else {
            indexMap[name] = (idxSeq, -1)
        }
    }
    
    fileprivate func removeIndex(_ name: String) {
        let DS = indexMap[name]
        if let DS = DS {
            let idx = getDynamicIndex(DS.idxD)
            if idx == dynamicTable.count - 1 {
                if DS.idxS == -1 {
                    indexMap.removeValue(forKey: name)
                } else {
                    indexMap[name]!.idxD = -1 // reset dynamic table index
                }
            }
        }
    }
    
    fileprivate func getIndex(_ name: String) -> (idxD: Int, idxS: Int) {
        let DS = indexMap[name]
        if let DS = DS {
            let d = getDynamicIndex(DS.idxD)
            let s = DS.idxS
            return (d, s)
        }
        return (-1, -1)
    }
    
    func getIndex(_ name: String, _ value: String) -> (Int, Bool) {
        var index = -1
        var indexD = -1
        var indexS = -1
        var valueIndexed = false
        (indexD, indexS) = getIndex(name)
        if indexD != -1 && indexD < dynamicTable.count
            && name == dynamicTable[indexD].name {
            index = indexD + HPACK_DYNAMIC_START_INDEX
            valueIndexed = dynamicTable[indexD].value == value
        } else if indexS != -1 && indexS < HPACK_STATIC_TABLE_SIZE
            && name == hpackStaticTable[indexS].name {
            index = indexS + 1
            valueIndexed = hpackStaticTable[indexS].value == value
        }
        return (index, valueIndexed)
    }
}
