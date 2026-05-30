import Foundation
import os

/// Plugin-wide logger. Inspect with:
///   log stream --predicate 'subsystem == "me.harke.bam.streamdeck"' --info
enum Log {
    private static let logger = Logger(subsystem: "me.harke.bam.streamdeck", category: "plugin")

    static func info(_ msg: String) { logger.info("\(msg, privacy: .public)") }
    static func error(_ msg: String) { logger.error("\(msg, privacy: .public)") }
}
