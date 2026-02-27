// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

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
}
