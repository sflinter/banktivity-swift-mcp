// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("BaseRepository", .serialized)
struct BaseRepositoryTests {

    @Test("Repository writes are serialized across concurrent callers")
    func performWriteSerializesConcurrentCallers() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let repository = BaseRepository(container: vault.container)
        let recorder = WriteOverlapRecorder()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let writeCount = 8

        for _ in 0..<writeCount {
            group.enter()
            queue.async {
                start.wait()
                do {
                    try repository.performWrite { _ in
                        recorder.enter()
                        Thread.sleep(forTimeInterval: 0.03)
                        recorder.leave()
                    }
                } catch {
                    recorder.record(error)
                }
                group.leave()
            }
        }

        for _ in 0..<writeCount {
            start.signal()
        }

        let result = group.wait(timeout: .now() + 5)
        #expect(result == .success)
        #expect(recorder.errors.isEmpty)
        #expect(recorder.maximumConcurrentWrites == 1)
    }
}

private final class WriteOverlapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWrites = 0
    private var maxActiveWrites = 0
    private var recordedErrors: [Error] = []

    var errors: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return recordedErrors
    }

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxActiveWrites
    }

    func enter() {
        lock.lock()
        activeWrites += 1
        maxActiveWrites = max(maxActiveWrites, activeWrites)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeWrites -= 1
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        recordedErrors.append(error)
        lock.unlock()
    }
}
