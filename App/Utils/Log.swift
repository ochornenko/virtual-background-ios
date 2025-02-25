//
//  Log.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/23/25.
//

import os.log

struct Log {
    private static let logger = Logger(subsystem: "com.ml.virtualbackground", category: "main")
    
    static func debug(_ message: String) {
        logger.debug("\(message)")
    }
    
    static func info(_ message: String) {
        logger.info("\(message)")
    }
    
    static func error(_ message: String) {
        logger.error("\(message)")
    }
}
