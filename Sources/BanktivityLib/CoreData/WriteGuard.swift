// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Whether anything holds the store, or whether we could not find out.
///
/// The third case is the point. `checkBanktivityProcess` used to answer a plain
/// `Bool`, and every way of failing -- `lsof` missing, the process not running,
/// unreadable output -- returned `false`, meaning "clear to write". A guard whose
/// error path is indistinguishable from its success path is not a guard.
public enum VaultHolderStatus: Sendable, Equatable {
    case clear
    case heldByBanktivity(details: String)
    case undetermined(reason: String)
}

/// How the holder of a store is discovered. Injectable so a test can assert the
/// blocking path, which nothing could do while this shelled out unconditionally.
public protocol VaultHolderProbe: Sendable {
    func status(forStorePath path: String) -> VaultHolderStatus
}

/// Guards write operations by checking if Banktivity.app has the database file open.
/// Uses lsof to detect if any process named "Banktivity" has the file open.
/// The holder check, callable synchronously.
///
/// `WriteGuard` is an actor, but the write choke point is a synchronous function
/// deep inside Core Data work and cannot await one. Rather than block on the
/// actor from a sync context -- a deadlock waiting to happen -- both share this,
/// so there is one probe, one cache, and one refusal message.
public final class VaultHolderMonitor: @unchecked Sendable {
    private let dbPath: String
    private let probe: any VaultHolderProbe
    private let lock = NSLock()
    private var cachedStatus: VaultHolderStatus = .clear
    private var cacheExpiry: Date = .distantPast
    private static let cacheTTL: TimeInterval = 3.0

    public init(dbPath: String, probe: any VaultHolderProbe = LsofVaultHolderProbe()) {
        self.dbPath = dbPath
        self.probe = probe
    }

    /// The cached holder status, refreshed at most every `cacheTTL` seconds.
    public func holderStatus() -> VaultHolderStatus {
        lock.lock()
        if Date() < cacheExpiry {
            defer { lock.unlock() }
            return cachedStatus
        }
        lock.unlock()

        let status = probe.status(forStorePath: dbPath)

        lock.lock()
        cachedStatus = status
        cacheExpiry = Date().addingTimeInterval(Self.cacheTTL)
        lock.unlock()
        return status
    }

    /// Nil when a write may proceed; the refusal message otherwise.
    public func writeRefusal() -> String? {
        switch holderStatus() {
        case .clear:
            return nil
        case .heldByBanktivity:
            return "Banktivity is currently open. Please close Banktivity before making changes to avoid database corruption."
        case .undetermined(let reason):
            // Fail closed. A probe that cannot answer is not a probe that said
            // yes, and a loud refusal beats a silent write into a store the app
            // may be holding. Verified before shipping that lsof does see
            // holders of this store, so this is the error path, not the normal one.
            return "Cannot determine whether Banktivity has the vault open (\(reason)); refusing the write."
        }
    }
}

public actor WriteGuard {
    /// `nonisolated` because the monitor is itself thread-safe and the write
    /// choke point is synchronous: it must reach the same cache without
    /// awaiting this actor from inside Core Data work.
    public nonisolated let monitor: VaultHolderMonitor

    public init(dbPath: String, probe: any VaultHolderProbe = LsofVaultHolderProbe()) {
        self.monitor = VaultHolderMonitor(dbPath: dbPath, probe: probe)
    }

    public func holderStatus() -> VaultHolderStatus {
        monitor.holderStatus()
    }

    /// Check if Banktivity.app is currently running with the database open.
    public func isBanktivityRunning() -> Bool {
        if case .heldByBanktivity = monitor.holderStatus() { return true }
        return false
    }

    /// Returns an error message if a write must not proceed, nil otherwise.
    ///
    /// Signature deliberately unchanged: all 74 existing call sites keep working
    /// and stay useful as early, message-rich exits. They are no longer the only
    /// thing between a caller and the store -- `VaultWriteGate` is consulted at
    /// the write choke point, where it cannot be forgotten.
    public func guardWriteAccess() -> String? {
        monitor.writeRefusal()
    }
}

/// Asks `lsof` which processes hold the store open.
public struct LsofVaultHolderProbe: VaultHolderProbe {
    public init() {}

    public func status(forStorePath path: String) -> VaultHolderStatus {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+c", "0", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return .undetermined(reason: "lsof output was not readable text")
            }

            // Check the COMMAND column (first field) for Banktivity, not the full line,
            // because the file path itself may contain "Banktivity" in a directory name.
            let holder = output.split(separator: "\n").first { line in
                let command = line.split(separator: " ", maxSplits: 1).first ?? ""
                return command.contains("Banktivity")
            }
            if let holder {
                return .heldByBanktivity(details: String(holder))
            }
            // lsof exits 1 with no output when nothing holds the file, which is
            // the ordinary case and not a failure.
            return .clear
        } catch {
            return .undetermined(reason: "lsof could not be run: \(error)")
        }
    }
}
