//
//  BackgroundTaskQueue.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import Combine

/// A single serial queue through which background GitHub mutations run, so the UI can show one
/// unified progress bar. Operations added while others are running are appended and executed one
/// at a time, in order. When the queue drains it resets and hides itself.
///
/// This replaces the app's previous fire-and-forget `Task {}` per drag/batch item, which could
/// overlap unpredictably and offered no visibility into how much work was pending.
@MainActor
final class BackgroundTaskQueue: ObservableObject {
    /// Title of the item currently being processed (typically an issue title).
    @Published private(set) var currentTitle: String = ""
    /// 1-based index of the item currently being processed within the current run.
    @Published private(set) var currentIndex: Int = 0
    /// Total number of items queued in the current run (grows if more are enqueued mid-run).
    @Published private(set) var total: Int = 0
    /// Whether the queue is actively processing work.
    @Published private(set) var isProcessing: Bool = false

    private struct Operation {
        let title: String
        let work: @MainActor () async -> Void
        /// When the operation joined the queue (perf instrumentation, issue #109).
        let enqueuedAt = PerfTimer()
    }

    private var pending: [Operation] = []
    private var isRunning = false
    private var completedInRun = 0

    /// Enqueues a fire-and-forget operation. `title` is shown in the progress bar while it runs.
    /// The work closure is `@MainActor`-isolated to match the rest of the app (and to avoid the
    /// `nonisolated(nonsending)` async-closure reabstraction mismatch under Swift 6.2).
    func enqueue(title: String, _ work: @escaping @MainActor () async -> Void) {
        pending.append(Operation(title: title, work: work))
        total += 1
        startIfNeeded()
    }

    /// Enqueues a whole batch of operations **up front** (so `total` reflects the full batch and
    /// the progress bar reads "X of N"), runs them serially in order, and returns their results
    /// once all complete. `onItemComplete(done, total)` fires after each item so callers (e.g. the
    /// transfer sheet) can update their own progress UI. Items complete in enqueue order.
    func enqueueAll<T>(
        _ items: [(title: String, work: @MainActor () async -> T)],
        onItemComplete: ((Int, Int) -> Void)? = nil
    ) async -> [T] {
        guard !items.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            var results = [T?](repeating: nil, count: items.count)
            var completed = 0
            let count = items.count
            for (index, item) in items.enumerated() {
                let work = item.work
                enqueue(title: item.title) {
                    let value = await work()
                    results[index] = value
                    completed += 1
                    onItemComplete?(completed, count)
                    if completed == count {
                        continuation.resume(returning: results.compactMap { $0 })
                    }
                }
            }
        }
    }

    private func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        isProcessing = true
        Task { await run() }
    }

    private func run() async {
        while !pending.isEmpty {
            let op = pending.removeFirst()
            completedInRun += 1
            currentIndex = completedInRun
            currentTitle = op.title
            let waited = op.enqueuedAt.elapsedString
            let runTimer = PerfTimer()
            await op.work()
            PerfTimer.log("queue op \(completedInRun)/\(total)", runTimer, "queueWait=\(waited)ms title=\"\(op.title)\"")
        }
        // Drained — reset so the progress bar hides.
        isRunning = false
        isProcessing = false
        total = 0
        currentIndex = 0
        completedInRun = 0
        currentTitle = ""
    }
}
