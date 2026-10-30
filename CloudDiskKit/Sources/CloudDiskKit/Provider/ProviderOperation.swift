import Foundation

/// Bridges one File Provider call to one Swift task.
///
/// The extension protocol wants a `Progress` back immediately and a completion handler later, and it
/// expects to cancel by calling `cancel()` on that progress. This type owns that handshake:
///
/// - the progress is cancellable and its cancellation handler cancels the task;
/// - the completion handler runs exactly once, even if cancellation and completion race;
/// - the progress reports real byte counts, so Finder's download bar reflects the transfer instead of
///   an invented percentage.
public final class ProviderOperation<Value>: @unchecked Sendable {

    let progress: Progress

    private let gate = NSLock()
    private var settled = false
    private var task: Task<Void, Never>?
    private let deliver: (Result<Value, Error>) -> Void

    init(totalUnitCount: Int64 = 0, deliver: @escaping (Result<Value, Error>) -> Void) {
        self.deliver = deliver
        let progress = Progress(totalUnitCount: totalUnitCount)
        progress.isCancellable = true
        self.progress = progress
    }

    /// Attaches the work and wires cancellation. `work` is expected to honour cancellation by
    /// throwing, which every CloudDisk service call does through `Task.checkCancellation()`.
    func start(_ work: @escaping (Progress) async throws -> Value) {
        let task = Task { [progress] in
            if progress.isCancelled {
                emit(.failure(DriveError.cancelled))
                return
            }
            do {
                emit(.success(try await work(progress)))
            } catch {
                emit(.failure(error))
            }
        }

        gate.lock()
        self.task = task
        let cancelledAlready = progress.isCancelled
        if !settled {
            progress.cancellationHandler = { [weak self] in self?.cancelRunningTask() }
        }
        gate.unlock()

        if cancelledAlready { task.cancel() }
    }

    private func cancelRunningTask() {
        gate.lock()
        let running = task
        gate.unlock()
        running?.cancel()
    }

    /// Runs the stored completion handler at most once.
    func emit(_ result: Result<Value, Error>) {
        gate.lock()
        guard !settled else {
            gate.unlock()
            return
        }
        settled = true
        gate.unlock()
        deliver(result)
    }
}
