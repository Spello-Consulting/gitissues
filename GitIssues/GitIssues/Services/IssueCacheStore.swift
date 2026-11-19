//
//  IssueCacheStore.swift
//  GitIssues
//
//  Issue #109 — persistent issue cache, so the list is on screen at launch.
//

import Foundation

extension Notification.Name {
    /// Posted after the on-disk issue cache is cleared from Settings. The list view model drops its
    /// in-memory issues and reloads from GitHub.
    static let issueCacheCleared = Notification.Name("issueCacheCleared")
}

/// What is saved to disk: the issue list plus the bookkeeping needed to resume syncing from it.
struct CachedIssueSnapshot: Codable {
    var schemaVersion: Int
    /// The GitHub account the issues belong to. A different signed-in user discards the cache.
    var userLogin: String
    var savedAt: Date
    /// When the last *complete* fetch started.
    var lastFullSyncAt: Date
    /// When the most recent fetch (full or incremental) started — the basis for incremental queries.
    var lastSyncAt: Date
    /// The "allow read-only repositories" setting the list was fetched under. If it differs now,
    /// the cache may lack (or wrongly include) archived-repo issues and a full sync is forced.
    var allowReadOnly: Bool
    var issues: [Issue]
}

/// Reads and writes the issue cache as a single JSON file in the app's sandbox container
/// (`Application Support/IssueCache/issues.json`). The GitHub token is never stored here — it
/// stays in the Keychain.
///
/// JSON encoding and decoding happen on the main actor (the model types' `Codable` conformances
/// are main-actor isolated in this module); file I/O runs on a background task, and writes are
/// chained so they land in order and atomically.
final class IssueCacheStore {
    static let shared = IssueCacheStore()

    /// Bump when `Issue` (or anything it contains) changes shape; older files are then discarded.
    static let schemaVersion = 1

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("IssueCache", isDirectory: true)
            .appendingPathComponent("issues.json")
    }

    private let fileURL: URL
    private var pendingWrite: Task<Void, Never>?

    /// Incremented by `clear()`. A view model records the value it started under and passes it to
    /// `save`, so a debounced save that fires *after* a sign-out or cache clear can't resurrect the
    /// file it just removed.
    private(set) var generation = 0

    init(fileURL: URL = IssueCacheStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: - Coding

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Load

    /// The saved snapshot, or `nil` when there is none, it is from another schema version, or it
    /// can't be decoded (in which case the bad file is deleted). Never throws: a broken cache must
    /// only ever mean "load normally".
    func load() async -> CachedIssueSnapshot? {
        // Anything still being written must land first so we read the latest file.
        await pendingWrite?.value

        let url = fileURL
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data else { return nil }

        let timer = PerfTimer()
        do {
            let snapshot = try Self.makeDecoder().decode(CachedIssueSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.schemaVersion else {
                AppLogger.shared.info("Discarding issue cache with schema \(snapshot.schemaVersion) (current \(Self.schemaVersion))")
                removeFile()
                return nil
            }
            PerfTimer.log("issue cache load", timer, "issues=\(snapshot.issues.count) bytes=\(data.count)")
            return snapshot
        } catch {
            AppLogger.shared.warning("Discarding unreadable issue cache: \(error.localizedDescription)")
            removeFile()
            return nil
        }
    }

    // MARK: - Save

    /// Writes `snapshot` unless the cache was cleared since `generation` was read.
    func save(_ snapshot: CachedIssueSnapshot, generation expected: Int) {
        guard expected == generation else { return }

        let timer = PerfTimer()
        guard let data = try? Self.makeEncoder().encode(snapshot) else {
            AppLogger.shared.warning("Could not encode issue cache")
            return
        }
        PerfTimer.log("issue cache encode", timer, "issues=\(snapshot.issues.count) bytes=\(data.count)", slowAfterMs: 20)

        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.shared.warning("Could not write issue cache: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Clear

    /// Deletes the cache (after any in-flight write) and invalidates saves made under the old
    /// generation. Called on sign-out, re-authorization and from Settings.
    func clear() {
        generation += 1
        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Waits for queued writes/removals to finish. Used by tests and before reading back.
    func waitForPendingWrites() async {
        await pendingWrite?.value
    }

    private func removeFile() {
        let url = fileURL
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.removeItem(at: url)
        }
    }
}
