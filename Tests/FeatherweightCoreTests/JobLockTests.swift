import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct JobLockTests {
    @Test func lockExcludesSecondHolder() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let url = tree.url("state/jobs.lock")
        let first = JobLock(url: url)
        let second = JobLock(url: url)

        #expect(first.tryLock())
        #expect(!second.tryLock())
        first.unlock()
        #expect(second.tryLock())
        #expect(!first.tryLock())
        second.unlock()
    }

    @Test func blockingLockWaitsForRelease() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let url = tree.url("jobs.lock")
        let holder = JobLock(url: url)
        #expect(holder.tryLock())

        let acquired = Locked(false)
        let waiter = JobLock(url: url)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            try? waiter.lock()
            acquired.value = true
            waiter.unlock()
            finished.signal()
        }.start()

        Thread.sleep(forTimeInterval: 0.2)
        #expect(!acquired.value)
        holder.unlock()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(acquired.value)
    }

    @Test func unopenableLockFileFailsInsteadOfPretendingToLock() throws {
        let tree = try TempTree(["jobs.lock/": ""])  // a directory where the lock file should be
        defer { tree.remove() }
        let lock = JobLock(url: tree.url("jobs.lock"))

        #expect(!lock.tryLock())
        #expect(throws: (any Error).self) { try lock.tryAcquire() }
        #expect(throws: (any Error).self) { try lock.lock() }
    }

    @Test func tryAcquireDistinguishesBusyFromFailure() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let url = tree.url("jobs.lock")
        let first = JobLock(url: url)
        let second = JobLock(url: url)

        #expect(try first.tryAcquire())
        #expect(try !second.tryAcquire())
        first.unlock()
    }
}
