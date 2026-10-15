import EMCore
import EMStorage
import Foundation

/// Runs one kind of job. `progress(fraction, message)`; throw `JobFailure.permanent` for errors retrying can't fix.
public protocol JobHandler: Sendable {
    func run(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws
}

public enum JobFailure: Error, LocalizedError, Sendable {
    case permanent(String)
    /// Not an error: try again later (e.g. on battery). Doesn't count as an attempt.
    case deferred(until: Date, reason: String)
    public var errorDescription: String? {
        switch self {
        case .permanent(let m): m
        case .deferred(_, let r): "Deferred: \(r)"
        }
    }
}

public enum JobEvent: Sendable, Equatable {
    case started(Job)
    case progress(jobID: String, sessionID: SessionID?, kind: Job.Kind, fraction: Double, message: String)
    case finished(Job)
    case failed(Job, error: String, willRetry: Bool)
    case deferred(Job, reason: String)
}

/// Persistent background job queue (EM-080). Jobs live in the `jobs` table, so a quit/crash mid-job resumes at
/// next launch. Per-kind concurrency limits (1 transcription, 2 LLM), exponential backoff, and a power gate for
/// heavy work (EM-088) that the user can override per session ("Transcribe now").
public actor JobRunner {
    public nonisolated let events: AsyncStream<JobEvent>
    private let continuation: AsyncStream<JobEvent>.Continuation
    private let repo: JobRepository
    private let handlers: [Job.Kind: JobHandler]
    private let limits: [Job.Kind: Int]
    private let heavyKinds: Set<Job.Kind>
    private let power: @Sendable () -> PowerState
    private let clock: EMClock
    private let maxAttempts: Int
    private var running: [String: (kind: Job.Kind, task: Task<Void, Never>)] = [:]
    private var forced: Set<SessionID> = []
    private var loop: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?

    public init(db: AppDatabase, handlers: [Job.Kind: JobHandler],
                limits: [Job.Kind: Int] = [.transcribe: 1, .summarize: 2, .finalizeAudio: 1, .export: 2],
                heavyKinds: Set<Job.Kind> = [.transcribe],
                power: @escaping @Sendable () -> PowerState = { PowerState.current() },
                clock: EMClock = SystemClock(), maxAttempts: Int = 4) {
        repo = JobRepository(db)
        self.handlers = handlers
        self.limits = limits
        self.heavyKinds = heavyKinds
        self.power = power
        self.clock = clock
        self.maxAttempts = maxAttempts
        (events, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .bufferingNewest(64))
    }

    /// Requeues jobs a crash left running, then processes the queue until `stop()`.
    public func start() {
        guard loop == nil else { return }
        let n = (try? repo.requeueInterrupted(now: clock.now)) ?? 0
        if n > 0 { Log.info(.jobs, "Resumed \(n) interrupted job(s)") }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = cont
        loop = Task { [weak self] in
            // Re-check every 30 s for not_before / power changes even without a wake-up.
            let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); cont.yield() } }
            defer { ticker.cancel() }
            await self?.drain()
            for await _ in stream {
                guard let self else { return }
                await self.drain()
            }
        }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        wake?.finish(); wake = nil
        running.values.forEach { $0.task.cancel() }
    }

    public func kick() { wake?.yield() }

    @discardableResult
    public func enqueue(_ kind: Job.Kind, sessionID: SessionID?, force: Bool = false) -> String? {
        if force, let sessionID { forced.insert(sessionID) }
        do {
            let id = try repo.enqueue(kind, sessionID: sessionID, now: clock.now)
            Log.info(.jobs, "Enqueued \(kind.rawValue) for \(sessionID?.description ?? "-")")
            kick()
            return id
        } catch {
            Log.error(.jobs, "Enqueue failed: \(error)")
            return nil
        }
    }

    /// "Transcribe now": ignore the power gate for this session and run as soon as a slot is free.
    public func force(_ sessionID: SessionID) { forced.insert(sessionID); kick() }

    public func cancel(sessionID: SessionID) {
        for job in (try? repo.jobs(for: sessionID)) ?? [] where job.status == .running || job.status == .queued {
            running[job.id]?.task.cancel()
            try? repo.fail(job.id, error: "Cancelled", retryAt: nil, now: clock.now)
        }
    }

    public var activeJobIDs: [String] { Array(running.keys) }

    // MARK: - Loop

    func drain() {
        for kind in handlers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            claiming: while (running.values.filter { $0.kind == kind }.count) < (limits[kind] ?? 1) {
                switch claim(kind) {
                case .run(let job): launch(job)
                case .deferred: continue claiming   // put back with a later not_before; look at the next job
                case .none: break claiming
                }
            }
        }
    }

    private enum Claim { case run(Job), deferred, none }

    private func claim(_ kind: Job.Kind) -> Claim {
        guard let job = try? repo.claimNext(kinds: [kind], now: clock.now) else { return .none }
        if heavyKinds.contains(kind), !(job.sessionID.map { forced.contains($0) } ?? false) {
            let p = power()
            if p.shouldDeferHeavyWork {
                let until = clock.now.addingTimeInterval(10 * 60)
                // Not a failure: put it back without counting the attempt.
                try? repo.fail(job.id, error: "Deferred: \(p.reason ?? "power")", retryAt: until, now: clock.now)
                try? repo.uncountAttempt(job.id)
                continuation.yield(.deferred(job, reason: p.reason ?? "power saving"))
                Log.info(.jobs, "Deferred \(kind.rawValue) (\(p.reason ?? "power")) until \(until)")
                return .deferred
            }
        }
        return .run(job)
    }

    private func launch(_ job: Job) {
        guard let handler = handlers[job.kind] else { return }
        continuation.yield(.started(job))
        Log.info(.jobs, "Started \(job.kind.rawValue) \(job.id) (attempt \(job.attempts))")
        let cont = continuation
        let task = Task { [weak self] in
            var outcome: Error?
            do {
                try await handler.run(job) { fraction, message in
                    cont.yield(.progress(jobID: job.id, sessionID: job.sessionID, kind: job.kind, fraction: fraction, message: message))
                }
                if Task.isCancelled { outcome = CancellationError() }
            } catch {
                outcome = error
            }
            await self?.finished(job, error: outcome)
        }
        running[job.id] = (job.kind, task)
    }

    private func finished(_ job: Job, error: Error?) {
        running[job.id] = nil
        if let sid = job.sessionID, job.kind == .transcribe { forced.remove(sid) }
        let now = clock.now
        if let error {
            if let f = error as? JobFailure, case let .deferred(until, reason) = f {
                try? repo.fail(job.id, error: "Deferred: \(reason)", retryAt: until, now: now)
                try? repo.uncountAttempt(job.id)
                continuation.yield(.deferred(job, reason: reason))
            } else {
                var permanent = error is CancellationError
                if let f = error as? JobFailure, case .permanent = f { permanent = true }
                let retry = !permanent && job.attempts < maxAttempts
                let retryAt = retry ? now.addingTimeInterval(Self.backoff(attempt: job.attempts)) : nil
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                try? repo.fail(job.id, error: message, retryAt: retryAt, now: now)
                continuation.yield(.failed(job, error: message, willRetry: retry))
                Log.error(.jobs, "\(job.kind.rawValue) \(job.id) failed (attempt \(job.attempts)): \(message)\(retry ? " — retrying" : "")")
            }
        } else {
            try? repo.complete(job.id, now: now)
            continuation.yield(.finished(job))
            Log.info(.jobs, "Finished \(job.kind.rawValue) \(job.id)")
        }
        drain()
    }

    /// 30 s, 2 min, 8 min, 32 min … capped at 1 h.
    public static func backoff(attempt: Int) -> TimeInterval {
        min(3600, 30 * pow(4, Double(max(0, attempt - 1))))
    }
}
