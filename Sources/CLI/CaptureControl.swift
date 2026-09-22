import Foundation

/// External control over a running live capture (PRD §6.9 interactive mode and
/// §6.10 remote-control agent): pause/resume — which drops captured audio so the
/// paused interval is a true gap, never written — and stop, which ends the
/// capture like Ctrl-C.
///
/// Thread-safe. A single instance is shared between the control front-end (the
/// interactive key reader, or an HTTP handler) and `CaptureEngine.run`, which
/// installs a stop handler to wake its wait loop and consults `isPaused` on the
/// capture I/O path.
final class CaptureControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var muted = false
    private var stopped = false
    private var pauses: UInt64 = 0
    private var onStop: (() -> Void)?
    private var callAudioSource: (@Sendable () -> TapSilenceMonitor.Status)?
    /// The open (not yet finalized) transcript line per capture source, with a
    /// monotonic `seq` so the newest one can be identified. Only
    /// `--live-streaming` writes here; with streaming off the map stays empty and
    /// `GET /status` is byte-identical to before.
    private var partials: [String: (line: PartialLine, seq: UInt64)] = [:]
    private var partialSeq: UInt64 = 0

    /// Signalled once the capture is open: every source started and the output
    /// ready, so anything audible from that moment on is recorded. `POST /start`
    /// waits for this before it answers, so a client told "recording" can start
    /// talking and be heard.
    /// Before this gate, `/start` answered the moment the session was registered
    /// and the whole setup happened afterwards, so everything said during it was
    /// lost: measured at 12.7 s on the first `--live-streaming` call after a
    /// reboot, where the recognizer's model is loaded cold.
    private let gate = NSCondition()
    private var capturing = false
    private var runEnded = false

    /// True once the capture is delivering audio, and it stays true for the rest
    /// of the run: a pause keeps the sources open.
    var isCapturing: Bool {
        gate.lock(); defer { gate.unlock() }
        return capturing
    }

    /// Called by the capture engine when audio starts flowing.
    func markCapturing() {
        gate.lock(); capturing = true; gate.broadcast(); gate.unlock()
    }

    /// Called when the run returns, so a waiter is released even if the run
    /// failed before it ever captured anything.
    func markRunEnded() {
        gate.lock(); runEnded = true; gate.broadcast(); gate.unlock()
    }

    /// Waits for the capture to start. Returns true when it is running, false
    /// when the run ended first or `timeout` passed.
    func waitUntilCapturing(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        gate.lock(); defer { gate.unlock() }
        while !capturing && !runEnded {
            if !gate.wait(until: deadline) { break }
        }
        return capturing
    }

    /// The same wait for the agent's request handler, which runs on Swift
    /// concurrency: polling keeps the cooperative thread free instead of parking
    /// it on the condition for up to a minute.
    func waitUntilCapturing(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (capturing, ended) = snapshotGate()
            if capturing || ended || Date() >= deadline { return capturing }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func snapshotGate() -> (capturing: Bool, runEnded: Bool) {
        gate.lock(); defer { gate.unlock() }
        return (capturing, runEnded)
    }

    /// True while capture is paused (the I/O path drops chunks).
    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// How many pause intervals have begun. Chunks are dropped one at a time on
    /// the capture I/O queue, so a pause can land *between* the two sources of a
    /// `--mix` capture and drop only one of them. A consumer that pairs the two
    /// sources (the `--tracks stereo` writer) watches this counter to realign at
    /// the pause boundary instead of carrying that offset for the rest of the
    /// recording.
    var pauseCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return pauses
    }

    /// True while the microphone is muted (interactive `m`, PRD §6.9). Unlike
    /// pause this silences **only** the mic — capture keeps running and the
    /// timeline is preserved — so it is read by the capture session, not the
    /// engine's chunk-drop path. Independent of `paused`.
    var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return muted
    }

    /// True once `stop()` has been requested.
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Health of the system-audio side, when the capture monitors it (a tap
    /// with a mic; see `TapSilenceMonitor`). nil otherwise.
    var callAudio: TapSilenceMonitor.Status? {
        lock.lock()
        let source = callAudioSource
        lock.unlock()
        return source?()
    }

    /// `CaptureEngine.run` installs the monitor's status reader.
    func setCallAudioSource(_ source: @escaping @Sendable () -> TapSilenceMonitor.Status) {
        lock.lock(); defer { lock.unlock() }
        callAudioSource = source
    }

    /// `CaptureEngine.run` installs a handler to wake its wait loop. If a stop
    /// was already requested before the handler was set, it fires immediately.
    func setStopHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onStop = handler
        let fireNow = stopped
        lock.unlock()
        if fireNow { handler() }
    }

    /// Toggles pause/resume; returns the new paused state. A no-op (returns the
    /// current state) once stopped.
    @discardableResult
    func togglePause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return paused }
        paused.toggle()
        if paused { pauses += 1 }
        return paused
    }

    /// Toggles microphone mute; returns the new muted state. A no-op (returns
    /// the current state) once stopped. Independent of pause.
    @discardableResult
    func toggleMute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return muted }
        muted.toggle()
        return muted
    }

    /// Mutes the microphone if not already muted; returns true if the state
    /// changed. A no-op once stopped. Independent of pause. Used by the
    /// remote-control agent's `POST /mute` (idempotent, unlike `toggleMute`).
    @discardableResult
    func mute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !muted, !stopped else { return false }
        muted = true
        return true
    }

    /// Unmutes the microphone if muted; returns true if the state changed. A
    /// no-op once stopped. Used by the remote-control agent's `POST /unmute`.
    @discardableResult
    func unmute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard muted, !stopped else { return false }
        muted = false
        return true
    }

    /// Pauses if running; returns true if the state changed.
    @discardableResult
    func pause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused, !stopped else { return false }
        paused = true
        pauses += 1
        return true
    }

    /// Resumes if paused; returns true if the state changed.
    @discardableResult
    func resume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard paused, !stopped else { return false }
        paused = false
        return true
    }

    /// Publishes (or, with nil, clears) the open transcript line for one capture
    /// source. A `--mix` capture streams two sources, so the newest line wins in
    /// `partialLine` rather than the two flickering against each other. Ignored
    /// once stopped, so a late decode can't resurrect a line after the recording
    /// ended.
    func setPartial(_ line: PartialLine?, for source: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            partials.removeValue(forKey: source)
            return
        }
        guard let line else {
            partials.removeValue(forKey: source)
            return
        }
        partialSeq += 1
        partials[source] = (line, partialSeq)
    }

    /// The most recently published open line across all sources, or nil when
    /// every source's line has closed.
    var partialLine: PartialLine? {
        lock.lock()
        defer { lock.unlock() }
        return partials.values.max(by: { $0.seq < $1.seq })?.line
    }

    /// Requests a graceful stop and wakes the capture wait loop (idempotent).
    func stop() {
        lock.lock()
        let handler: (() -> Void)?
        if stopped {
            handler = nil
        } else {
            stopped = true
            paused = false
            muted = false
            partials.removeAll()
            handler = onStop
        }
        lock.unlock()
        handler?()
    }
}
