import Foundation

/// Guards write operations by checking if Banktivity.app has the database file open.
/// Uses lsof to detect if any process named "Banktivity" has the file open.
public actor WriteGuard {
    private let dbPath: String
    private var cachedResult: Bool = false
    private var cacheExpiry: Date = .distantPast
    private static let cacheTTL: TimeInterval = 3.0

    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Check if Banktivity.app is currently running with the database open.
    /// Returns true if Banktivity is running (writes should be blocked).
    public func isBanktivityRunning() -> Bool {
        let now = Date()
        if now < cacheExpiry {
            return cachedResult
        }

        let result = checkBanktivityProcess()
        cachedResult = result
        cacheExpiry = now.addingTimeInterval(Self.cacheTTL)
        return result
    }

    /// Returns an error message if Banktivity is running, nil otherwise.
    public func guardWriteAccess() -> String? {
        if isBanktivityRunning() {
            return "Banktivity is currently open. Please close Banktivity before making changes to avoid database corruption."
        }
        return nil
    }

    private func checkBanktivityProcess() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+c", "0", dbPath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            // Check the COMMAND column (first field) for Banktivity, not the full line,
            // because the file path itself may contain "Banktivity" in a directory name.
            return output.split(separator: "\n").contains { line in
                let command = line.split(separator: " ", maxSplits: 1).first ?? ""
                return command.contains("Banktivity")
            }
        } catch {
            // lsof exits with code 1 when no matches found, or may not exist
            return false
        }
    }
}
