// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public enum RepositoryError: Error, CustomStringConvertible {
    case unexpectedNilResult

    public var description: String {
        switch self {
        case .unexpectedNilResult: return "Write block completed without producing a result"
        }
    }

    public var cliExitCategory: CLIExitCategory {
        .runtimeStoreFailure
    }
}

public enum ToolError: Error, CustomStringConvertible {
    case notFound(String)
    case missingParameter(String)
    case writeBlocked(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .notFound(let msg): return msg
        case .missingParameter(let msg): return msg
        case .writeBlocked(let msg): return msg
        case .invalidInput(let msg): return msg
        }
    }

    public var cliExitCategory: CLIExitCategory {
        switch self {
        case .missingParameter:
            return .usageInput
        case .invalidInput:
            return .validationFailed
        case .notFound:
            return .notFound
        case .writeBlocked:
            return .writeBlocked
        }
    }
}

public enum CLIExitCategory: String, Codable, Sendable {
    case usageInput = "usage_input"
    case notFound = "not_found"
    case writeBlocked = "write_blocked"
    case validationFailed = "validation_failed"
    case runtimeStoreFailure = "runtime_store_failure"

    public var exitCode: Int32 {
        switch self {
        case .usageInput:
            return 64
        case .validationFailed:
            return 65
        case .notFound:
            return 66
        case .runtimeStoreFailure:
            return 70
        case .writeBlocked:
            return 77
        }
    }
}
