import Foundation
import OSLog

public struct KeydLogger: Sendable {
    private let category: String
    private let logger: Logger

    public init(category: String, subsystem: String = "com.ryheff.keyd") {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    public func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        mirrorToStandardError(message)
    }

    private func mirrorToStandardError(_ message: String) {
        #if DEBUG
        guard let data = "[\(category)] \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        #endif
    }
}
