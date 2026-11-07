import Foundation
import os

/// Small cancellation flag shared between a long-running job and the UI.
final class CancelFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { lock.withLock { $0 } }
    func cancel() { lock.withLock { $0 = true } }
}

/// Runs blocking work on a background queue without tying up the Swift concurrency pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

/// Maps `items` through `transform` with at most `width` running at once. Results keep input order;
/// entries are nil if the job was cancelled before they ran.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T], width: Int = ProcessInfo.processInfo.activeProcessorCount, cancel: CancelFlag,
    onProgress: (@Sendable (Int) -> Void)? = nil,
    _ transform: @escaping @Sendable (T) -> R
) async -> [R?] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        var done = 0
        func enqueue() {
            guard next < items.count, !cancel.isCancelled else { return }
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, transform(item)) }
        }
        for _ in 0..<min(width, items.count) { enqueue() }
        while let (index, value) = await group.next() {
            results[index] = value
            done += 1
            onProgress?(done)
            enqueue()
        }
        return results
    }
}

/// Like `concurrentMap`, but the work itself is async (for Vision's async requests).
func concurrentMapAsync<T: Sendable, R: Sendable>(
    _ items: [T], width: Int = 4, cancel: CancelFlag,
    onProgress: (@Sendable (Int) -> Void)? = nil,
    _ transform: @escaping @Sendable (T) async -> R
) async -> [R?] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        var done = 0
        func enqueue() {
            guard next < items.count, !cancel.isCancelled else { return }
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        for _ in 0..<min(width, items.count) { enqueue() }
        while let (index, value) = await group.next() {
            results[index] = value
            done += 1
            onProgress?(done)
            enqueue()
        }
        return results
    }
}

/// Runs blocking work on a few dedicated GCD threads (not Swift's cooperative pool). Needed for Vision,
/// which blocks its caller and can stall if many requests are issued from a saturated pool.
/// Call this from inside `runBlocking`.
func blockingParallelMap<T: Sendable, R: Sendable>(
    _ items: [T], width: Int = 3, cancel: CancelFlag,
    onProgress: (@Sendable (Int) -> Void)? = nil,
    _ transform: @Sendable (T) -> R
) -> [R?] {
    let next = OSAllocatedUnfairLock(initialState: 0)
    let done = OSAllocatedUnfairLock(initialState: 0)
    var results = [R?](repeating: nil, count: items.count)
    results.withUnsafeMutableBufferPointer { buffer in
        nonisolated(unsafe) let out = buffer
        DispatchQueue.concurrentPerform(iterations: max(1, min(width, items.count))) { _ in
            while !cancel.isCancelled {
                let i = next.withLock { value -> Int in let current = value; value += 1; return current }
                if i >= items.count { break }
                out[i] = transform(items[i])
                let finished = done.withLock { value -> Int in value += 1; return value }
                onProgress?(finished)
            }
        }
    }
    return results
}
