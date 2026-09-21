import Foundation

/// Tells a dead system tap from a quiet call.
///
/// With a microphone clocking the capture, a tap that dies keeps delivering
/// buffers, all zeros, so the stall watchdog never sees it. Zeros alone prove
/// nothing: a call where nobody talks is exact digital silence for minutes. So
/// a long zero run only earns a *probe*: a throwaway second tap that listens
/// briefly. Probe hears audio while the live tap still delivers zeros = the
/// live tap is dead, restart it. Probe hears nothing = the room is quiet, do
/// nothing and look again later.
///
/// Pure decision logic over an injected clock, like `StallWatchdog`; the owner
/// (`CaptureEngine.run`) runs the probe and the restart. The contract:
///   * `observe(silent:)` once per IO cycle of the tap stream.
///   * `setPaused(_:)` so a paused recording is never probed or rebuilt.
///   * `tick()` on a fixed cadence; act on the returned `Action`.
///   * `probeFinished(heardAudio:)` when a probe asked for by `tick()` ends.
///
/// Probes run when the zero run reaches `silenceSeconds`, then 3x, 6x, and
/// every further 6x of it (10 s, 30 s, 60 s, then each minute). Restarts ride
/// the same schedule, so a restart that does not bring audio back is retried
/// at a widening interval and at most `maxRestarts` times per zero run. Any
/// non-silent cycle ends the run and resets all of it. So does the stream
/// going quiet altogether: when cycles stop arriving the capture has stalled,
/// which is the stall watchdog's case, and this monitor stands aside.
final class TapSilenceMonitor: @unchecked Sendable {
    enum State: String, Sendable {
        /// Audio is flowing, or the zero run is still too short to question.
        case ok
        /// Zeros, and the last probe heard nothing either: a quiet room.
        case silent
        /// A probe heard audio the live tap does not: restart pending, or it
        /// did not bring audio back (yet).
        case dead
        /// Audio came back after a restart. Stays until the next long zero run.
        case recovered
    }

    struct Status: Equatable, Sendable {
        let state: State
        /// Length of the current zero run in seconds (0 while audio flows).
        let silentFor: Double
        /// Tap restarts this monitor has asked for since capture began.
        let restarts: Int
    }

    enum Action: Equatable {
        case none
        /// Run a probe, then call `probeFinished`.
        case probe
        /// The live tap is dead: rebuild it. `attempt` counts within this run.
        case restart(silentFor: Double, attempt: Int)
        /// Restarts did not help; no more will be tried during this zero run.
        case gaveUp(silentFor: Double)
    }

    private let silenceSeconds: Double
    private let confirmSeconds: Double
    private let maxRestarts: Int
    private let now: () -> Date
    private let lock = NSLock()

    private var state = State.ok
    private var restarts = 0
    private var runStartedAt: Date?
    private var lastSilentCycleAt: Date?
    /// A zero run with no cycle for this long is a stalled stream, not a silent one.
    private var staleSeconds: Double { min(2, silenceSeconds) }
    /// Bumped whenever a zero run ends, so a probe that outlives its run is ignored.
    private var runID = 0
    private var probesDone = 0
    private var restartsThisRun = 0
    private var probingRunID: Int?
    private var confirmAt: Date?
    private var announcedGiveUp = false
    private var paused = false

    init(
        silenceSeconds: Double = 10,
        confirmSeconds: Double = 0.5,
        maxRestarts: Int = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.silenceSeconds = max(0.5, silenceSeconds)
        self.confirmSeconds = max(0, confirmSeconds)
        self.maxRestarts = max(1, maxRestarts)
        self.now = now
    }

    /// Zero-run age at which probe number `index` (0-based) is due.
    private func probeAge(_ index: Int) -> Double {
        switch index {
        case 0: return silenceSeconds
        case 1: return silenceSeconds * 3
        default: return silenceSeconds * 6 * Double(index - 1)
        }
    }

    /// Records one IO cycle of the tap stream. IO path: a lock and no allocation.
    func observe(silent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused else { return }
        if silent {
            let t = now()
            if runStartedAt == nil { runStartedAt = t }
            lastSilentCycleAt = t
            return
        }
        guard runStartedAt != nil else { return }
        if restartsThisRun > 0 {
            state = .recovered
        } else if state != .recovered {
            state = .ok
        }
        endRun()
    }

    /// Tracks pause state. Pausing ends the current zero run (a probe still in
    /// flight is ignored), and nothing is observed or asked for while paused, so
    /// a zero run never ages across a pause. Only acts on a transition.
    func setPaused(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard value != paused else { return }
        paused = value
        if value, runStartedAt != nil { endRun() }
    }

    private func endRun() {
        runStartedAt = nil
        runID += 1
        probesDone = 0
        restartsThisRun = 0
        confirmAt = nil
        announcedGiveUp = false
    }

    func tick() -> Action {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, let runStartedAt else { return .none }
        let t = now()
        if let last = lastSilentCycleAt, t.timeIntervalSince(last) > staleSeconds {
            endRun()
            return .none
        }
        let age = t.timeIntervalSince(runStartedAt)

        // A probe heard audio. The live tap gets a moment to show the same
        // audio (it would have ended the run); still zeros now means dead.
        if let confirm = confirmAt {
            guard t >= confirm else { return .none }
            confirmAt = nil
            guard restartsThisRun < maxRestarts else {
                if announcedGiveUp { return .none }
                announcedGiveUp = true
                return .gaveUp(silentFor: age)
            }
            restartsThisRun += 1
            restarts += 1
            return .restart(silentFor: age, attempt: restartsThisRun)
        }

        guard probingRunID == nil, !announcedGiveUp, age >= probeAge(probesDone) else {
            return .none
        }
        probingRunID = runID
        return .probe
    }

    func probeFinished(heardAudio: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let probedRun = probingRunID
        probingRunID = nil
        // Audio came back while the probe ran: its verdict is about a run that
        // no longer exists.
        guard probedRun == runID, runStartedAt != nil else { return }
        probesDone += 1
        if heardAudio {
            state = .dead
            confirmAt = now().addingTimeInterval(confirmSeconds)
        } else {
            state = .silent
        }
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        let silentFor = runStartedAt.map { now().timeIntervalSince($0) } ?? 0
        return Status(state: state, silentFor: silentFor, restarts: restarts)
    }
}
