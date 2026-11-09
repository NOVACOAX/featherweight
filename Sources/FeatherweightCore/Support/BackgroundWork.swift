import Foundation

enum BackgroundWork {
    /// Runs `body` on a new thread at background QoS and waits for its result. Background QoS
    /// gives the thread low CPU priority and throttled disk I/O.
    ///
    /// A dedicated thread is used because a thread cannot raise its QoS again after lowering it,
    /// so the caller's own priority could not be restored.
    ///
    /// No thread-scope `setiopolicy_np` call is made: setting an I/O policy on a thread opts it out
    /// of QoS (`qos_class_self()` becomes unspecified and the thread runs at default CPU
    /// priority), and QoS cannot be set again afterwards.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let result = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.value = body()
            done.signal()
        }
        thread.qualityOfService = .background
        thread.start()
        done.wait()
        return result.value!
    }

    /// Written once by the worker before `signal()`, read once after `wait()`; the semaphore
    /// orders the two accesses.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
