// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Serializes Core Data write contexts inside the current process.
///
/// This covers concurrent MCP tool calls handled by one `banktivity-mcp` server
/// process and overlapping writes inside one CLI command. It does not coordinate
/// two separate `banktivity-cli` or `banktivity-mcp` processes pointed at the
/// same vault.
/// The one place a write can be refused regardless of how it was reached.
///
/// Every guard deciding whether a write may proceed lived at a per-verb call
/// site, so a route that was not one -- a second entrance, a nested command, a
/// verb someone forgot to annotate -- was unguarded by construction. Guards you
/// have to remember to call are guards that get missed.
///
/// Installed once per process by whichever entry point opened the vault. The
/// default is permissive on purpose: this is a library others embed, and a
/// fail-closed default would refuse every write in a process that never opted
/// in, including the test suite. That does leave a gate you can forget to
/// install; removing that last gap means threading a vault handle through
/// repository construction so there is no uninstalled state to have, which is
/// a larger change than belongs here.
public enum VaultWriteGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refusalProvider: (@Sendable () -> String?)?

    /// Install the process-wide write gate. Later calls replace the earlier one.
    public static func install(_ provider: @escaping @Sendable () -> String?) {
        lock.lock()
        defer { lock.unlock() }
        refusalProvider = provider
    }

    /// Remove the gate. For tests; production installs once and leaves it.
    public static func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        refusalProvider = nil
    }

    public static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refusalProvider != nil
    }

    /// Nil when a write may proceed; the refusal message otherwise.
    static func refusal() -> String? {
        lock.lock()
        let provider = refusalProvider
        lock.unlock()
        return provider?()
    }
}

enum CoreDataWriteCoordinator {
    private static let queueKey = DispatchSpecificKey<Void>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.sflinter.banktivity-swift-mcp.core-data-writes")
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    /// Every passage through here is a save; reads never reach the coordinator.
    static func perform<T>(_ block: () throws -> T) throws -> T {
        if let refusal = VaultWriteGate.refusal() {
            throw ToolError.writeBlocked(refusal)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }
}
