// File: TileBlockKit/TileBlockDiagnostics.swift
import Foundation
import os.log

final class TileBlockDiagnostics {
    static let shared = TileBlockDiagnostics()

    private let logger = Logger(subsystem: "SpatialHashGrid.TileBlockKit", category: "Diagnostics")
    var isEnabled = true {
        didSet {
            if isEnabled {
                logger.info("TileBlock diagnostics enabled")
            } else {
                logger.info("TileBlock diagnostics disabled")
            }
        }
    }

    private init() {}

    func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = message()
        logger.debug("\(message, privacy: .public)")
    }
}
