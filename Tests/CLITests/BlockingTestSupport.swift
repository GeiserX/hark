import Foundation

/// Runs `work` on a dedicated thread and suspends (never blocks) the caller until
/// it finishes.
///
/// Some of hark's shipping API blocks its calling thread while the work that
/// unblocks it runs on the Swift concurrency pool: `StreamingLiveTranscriber`'s
/// `finalize()` waits on a semaphore its consumer `Task` signals, and
/// `RunLoopBridge.runBlocking` spins a `RunLoop` while polling a child `Task`.
/// In production both are called from a real thread (`Hark.run` on main), so they
/// are safe there. A test body is a `Task` on the cooperative pool, and with
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (what CI sets) that pool is one thread
/// wide: calling them inline blocks the only worker and starves the very work the
/// call is waiting for, so the wait always expires. Wrapping the call here
/// reproduces the production thread instead.
func offCooperativePool<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let thread = Thread { continuation.resume(with: Result { try work() }) }
        thread.stackSize = 4 << 20
        thread.start()
    }
}
