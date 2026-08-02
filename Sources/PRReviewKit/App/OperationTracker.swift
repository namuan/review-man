import Foundation

/// Identifies a family of GitHub operations that supersede each other.
enum OperationLane: Hashable {
    case fetch
    case submit
    case reply(threadID: String)
    case resolve(threadID: String)
    case persistence
}

/// A unique operation instance within a lane.
struct OperationToken: Hashable {
    let lane: OperationLane
    let sequence: UInt64
}

/// Tracks operations independently per lane, replacing the old global
/// generation counter. Only the newest token per lane is current: a stale
/// completion (an older fetch, or an older resolve on the same thread) is
/// dropped without touching the model. Operations on different lanes (submit
/// vs refresh, or resolves on different threads) never invalidate each other.
final class OperationTracker {

    private let lock = NSLock()
    private var current: [OperationLane: UInt64] = [:]
    private var active: Set<OperationToken> = []
    private var fetchTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?

    /// Begins an operation in `lane` and marks it active and current.
    func begin(_ lane: OperationLane) -> OperationToken {
        lock.lock()
        let seq = (current[lane] ?? 0) + 1
        current[lane] = seq
        let token = OperationToken(lane: lane, sequence: seq)
        active.insert(token)
        lock.unlock()
        return token
    }

    /// True only for the newest token in the token's lane.
    func isCurrent(_ token: OperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current[token.lane] == token.sequence
    }

    /// Marks a token as no longer active (after it is accepted or dropped).
    func complete(_ token: OperationToken) {
        lock.lock()
        active.remove(token)
        lock.unlock()
    }

    var hasActiveOperations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !active.isEmpty
    }

    /// Cancels the previous in-flight fetch task without touching the lane.
    /// Called when a new fetch starts (the new token's `begin` already
    /// supersedes the old outcome).
    func cancelPreviousFetchTask() {
        lock.lock()
        let task = fetchTask
        lock.unlock()
        task?.cancel()
    }

    /// Explicit user cancellation: cancels the in-flight fetch task AND
    /// invalidates its lane, so that even a cancellation-uncooperative service
    /// cannot apply a stale fetch outcome afterwards.
    func cancelFetch() {
        lock.lock()
        current[.fetch] = (current[.fetch] ?? 0) + 1
        let task = fetchTask
        lock.unlock()
        task?.cancel()
    }

    func setFetchTask(_ task: Task<Void, Never>) {
        lock.lock()
        fetchTask = task
        lock.unlock()
    }

    /// Records the in-flight head-SHA migration task so a superseding fetch or
    /// explicit cancellation can abandon it.
    func setMigrationTask(_ task: Task<Void, Never>) {
        lock.lock()
        migrationTask = task
        lock.unlock()
    }
}
