//
//  Logging.swift
//
//
//  Created by Márton Aczél on 19/07/2024.
//

import OSLog

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    
    static let elm327 = Logger(subsystem: subsystem, category: "ELM327")
    static let obd2service = Logger(subsystem: subsystem, category: "obd2service")
    
    static let wifiMgr = Logger(subsystem: subsystem, category: "WiFiMgr")
    static let mockMgr = Logger(subsystem: subsystem, category: "MOCKMgr")
    static let blueMgr = Logger(subsystem: subsystem, category: "BlueMgr")
    
}
