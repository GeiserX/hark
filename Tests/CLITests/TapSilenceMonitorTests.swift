import Encoders
import Foundation
import TapEngine
import Testing

@testable import CLI

@Suite("Tap silence monitor")
struct TapSilenceMonitorTests {
    /// Mutable clock the monitor reads through its injected `now`.
    private final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1000)
        var now: @Sendable () -> Date { { [self] in t } }
    }

    private func monitor(_ clock: Clock, maxRestarts: Int = 5) -> TapSilenceMonitor {
        TapSilenceMonitor(
            silenceSeconds: 10, confirmSeconds: 0.5, maxRestarts: maxRestarts, now: clock.now)
    }

    /// `seconds` of zeros, one silent cycle per second (cycles keep arriving).
    private func zeros(_ m: TapSilenceMonitor, _ clock: Clock, seconds: Int) {
        m.observe(silent: true)
        for _ in 0..<seconds {
            clock.t += 1
            m.observe(silent: true)
        }
    }

    /// Advances the clock second by second through a zero run, answering every
    /// probe with `heard`, and returns the run ages at which probes/restarts fired.
    private func run(
        _ m: TapSilenceMonitor, _ clock: Clock, seconds: Int, heard: Bool
    ) -> (probes: [Int], restarts: [Int], gaveUp: [Int]) {
        var probes: [Int] = [], restarts: [Int] = [], gaveUp: [Int] = []
        m.observe(silent: true)
        for second in 1...seconds {
            clock.t += 1
            m.observe(silent: true)
            switch m.tick() {
            case .none: break
            case .probe:
                probes.append(second)
                m.probeFinished(heardAudio: heard)
            case .restart: restarts.append(second)
            case .gaveUp: gaveUp.append(second)
            }
        }
        return (probes, restarts, gaveUp)
    }

    @Test func shortZeroRunsNeverProbe() {
        let clock = Clock()
        let m = monitor(clock)
        for _ in 0..<20 {
            zeros(m, clock, seconds: 9)  // just under the threshold, like a pause between speakers
            #expect(m.tick() == .none)
            m.observe(silent: false)
            clock.t += 1
            #expect(m.tick() == .none)
        }
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
    }

    /// The pre-meeting case: minutes of exact zeros, nothing playing. Probes
    /// back off, agree it is quiet, and nothing is ever restarted.
    @Test func quietRoomProbesWithBackoffAndNeverRestarts() {
        let clock = Clock()
        let m = monitor(clock)
        let result = run(m, clock, seconds: 200, heard: false)
        #expect(result.probes == [10, 30, 60, 120, 180])
        #expect(result.restarts.isEmpty)
        #expect(m.status() == .init(state: .silent, silentFor: 200, restarts: 0))

        m.observe(silent: false)
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
        // The next run starts the schedule over.
        #expect(run(m, clock, seconds: 35, heard: false).probes == [10, 30])
    }

    @Test func deadTapRestartsThenReportsRecovered() {
        let clock = Clock()
        let m = monitor(clock)
        m.observe(silent: false)
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        #expect(m.tick() == .none)  // one probe at a time
        m.probeFinished(heardAudio: true)
        #expect(m.status().state == .dead)
        #expect(m.tick() == .none)  // confirmation window
        clock.t += 1
        m.observe(silent: true)  // live tap still zeros
        #expect(m.tick() == .restart(silentFor: 11, attempt: 1))
        #expect(m.status() == .init(state: .dead, silentFor: 11, restarts: 1))

        m.observe(silent: false)  // the rebuilt tap hears the call
        #expect(m.status() == .init(state: .recovered, silentFor: 0, restarts: 1))
        #expect(m.tick() == .none)

        // "recovered" lasts until the next long zero run is judged.
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.probeFinished(heardAudio: false)
        #expect(m.status().state == .silent)
        m.observe(silent: false)
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 1))
    }

    /// The probe and the live tap hear the same sound starting; the live tap's
    /// non-silent cycle lands inside the confirmation window. No restart.
    @Test func audioReturningDuringConfirmationCancelsTheRestart() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.probeFinished(heardAudio: true)
        clock.t += 0.1
        m.observe(silent: false)
        clock.t += 1
        #expect(m.tick() == .none)
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
    }

    /// A probe that outlives its zero run says nothing about the next one.
    @Test func staleProbeVerdictIsIgnored() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.observe(silent: false)  // audio back while the probe is still running
        m.observe(silent: true)  // a new run begins
        m.probeFinished(heardAudio: true)
        zeros(m, clock, seconds: 5)
        #expect(m.tick() == .none)
        #expect(m.status().state == .ok)
        #expect(m.status().restarts == 0)
    }

    /// A paused recording is never probed, and the zero run doesn't age across
    /// the pause: after resuming, the full threshold applies again.
    @Test func pauseEndsTheRunAndNothingHappensWhilePaused() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 9)
        m.setPaused(true)
        for _ in 0..<120 {
            clock.t += 1
            m.observe(silent: true)  // the tap keeps cycling while paused
            #expect(m.tick() == .none)
        }
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
        m.setPaused(false)
        zeros(m, clock, seconds: 9)
        #expect(m.tick() == .none)  // 9 s since resuming, not 138 s
        zeros(m, clock, seconds: 1)
        #expect(m.tick() == .probe)
    }

    /// A probe asked for before a pause answers after it: ignored.
    @Test func probeVerdictFromBeforeAPauseIsIgnored() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.setPaused(true)
        m.probeFinished(heardAudio: true)
        m.setPaused(false)
        zeros(m, clock, seconds: 5)
        #expect(m.tick() == .none)
        #expect(m.status() == .init(state: .ok, silentFor: 5, restarts: 0))
    }

    /// Cycles stop arriving (a stalled stream): that is the stall watchdog's
    /// case. Ticks with no `observe` calls never probe or restart.
    @Test func ticksWithoutCyclesNeverAct() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 5)
        for _ in 0..<300 {
            clock.t += 1
            #expect(m.tick() == .none)
        }
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
    }

    /// Pausing (or a stalled stream) during a `silent` or `dead` run must not
    /// leave that verdict on display for a run that no longer exists.
    @Test func endingARunWithoutAudioClearsSilentAndDead() {
        let clock = Clock()
        let m = monitor(clock)
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.probeFinished(heardAudio: false)
        #expect(m.status().state == .silent)
        m.setPaused(true)
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))
        m.setPaused(false)

        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.probeFinished(heardAudio: true)
        #expect(m.status().state == .dead)
        clock.t += 5  // cycles stop arriving: the stall watchdog's case
        #expect(m.tick() == .none)
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))

        // `recovered` is history, not a verdict on the run: it survives.
        zeros(m, clock, seconds: 10)
        #expect(m.tick() == .probe)
        m.probeFinished(heardAudio: true)
        clock.t += 1
        m.observe(silent: true)
        #expect(m.tick() == .restart(silentFor: 11, attempt: 1))
        m.restartFinished()
        m.observe(silent: false)
        zeros(m, clock, seconds: 3)
        m.setPaused(true)
        #expect(m.status().state == .recovered)
    }

    /// A rebuild that takes 3 s delivers no cycles meanwhile. That must not
    /// read as a stalled stream, or the backoff and the cap of 5 reset and a
    /// tap that stays dead is rebuilt every 10 s forever.
    @Test func slowRebuildsKeepTheBackoffAndTheCap() {
        let clock = Clock()
        let m = monitor(clock)
        var restarts: [Int] = [], gaveUp = 0
        m.observe(silent: true)
        let start = clock.t
        while clock.t.timeIntervalSince(start) < 900 {
            clock.t += 1
            m.observe(silent: true)
            switch m.tick() {
            case .probe: m.probeFinished(heardAudio: true)
            case .restart:
                restarts.append(Int(clock.t.timeIntervalSince(start)))
                clock.t += 3  // restart() blocks the tick queue; no cycles arrive
                m.restartFinished()
                #expect(m.tick() == .none)  // the tick that fires right after
            case .gaveUp: gaveUp += 1
            case .none: break
            }
        }
        #expect(restarts == [11, 31, 61, 121, 181])
        #expect(gaveUp == 1)
        #expect(m.status().state == .dead)
        m.observe(silent: false)
        #expect(m.status() == .init(state: .recovered, silentFor: 0, restarts: 5))
    }

    /// Restarts that don't bring audio back ride the probe backoff and stop at
    /// the cap; the recording is never stopped.
    @Test func failedRestartsBackOffAndAreCapped() {
        let clock = Clock()
        let m = monitor(clock, maxRestarts: 3)
        let result = run(m, clock, seconds: 600, heard: true)
        #expect(result.probes == [10, 30, 60, 120])
        #expect(result.restarts == [11, 31, 61])
        #expect(result.gaveUp == [121])
        #expect(m.status() == .init(state: .dead, silentFor: 600, restarts: 3))

        m.observe(silent: false)  // audio returns on its own: everything resets
        #expect(m.status().state == .recovered)
        #expect(run(m, clock, seconds: 12, heard: true).restarts == [11])
    }
}

/// A tap session whose tap-side silence and probe verdict the test drives, so
/// `CaptureEngine.run`'s dead-tap wiring can be exercised end to end.
private final class TapStubSession: TapHealthCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?
    private var restarts = 0
    private var probes = 0
    private var probeAnswer = TapProbeResult.silent
    private var restartSeconds = 0.0
    private var restarting = false
    private(set) var stoppedDuringRestart = false
    var onTapActivity: (@Sendable (_ silent: Bool) -> Void)?
    let reportsTapActivity = true
    let tapDiagnostics = "stub tap"

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {
        lock.lock(); if restarting { stoppedDuringRestart = true }; lock.unlock()
    }
    func restart() -> Bool {
        lock.lock(); restarts += 1; restarting = true; let hold = restartSeconds; lock.unlock()
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        lock.lock(); restarting = false; lock.unlock()
        return true
    }
    var isRestarting: Bool { lock.lock(); defer { lock.unlock() }; return restarting }
    func setRestartSeconds(_ value: Double) { lock.lock(); restartSeconds = value; lock.unlock() }
    func probeTap(maxSeconds: Double) -> TapProbeResult {
        lock.lock(); defer { lock.unlock() }
        probes += 1
        return probeAnswer
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    var restartCount: Int { lock.lock(); defer { lock.unlock() }; return restarts }
    var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
    func setProbeResult(_ value: TapProbeResult) { lock.lock(); probeAnswer = value; lock.unlock() }
    /// One IO cycle: the mic keeps the buffers coming either way.
    func cycle(tapSilent: Bool) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(Data(repeating: 1, count: 320))
        onTapActivity?(tapSilent)
    }
}

private final class NullSink: AudioSink, @unchecked Sendable {
    let label = "null"
    func write(_ data: Data) throws {}
    func finalize() throws {}
    var bytesWritten: UInt64 { 0 }
}

@Suite("Dead tap recovery", .serialized)
struct DeadTapRecoveryTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private func start(
        _ session: TapStubSession, _ control: CaptureControl, stallSeconds: Double = 3
    ) -> DispatchSemaphore {
        var eng = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        eng.control = control
        eng.recovery = RecoverySettings(
            enabled: true, stallSeconds: stallSeconds, giveUpSeconds: 0, tapSilenceSeconds: 0.5)
        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (eng, session, format))
        Thread.detachNewThread {
            let (eng, session, format) = box.value
            try? eng.run(
                session: session, format: format, into: [NullSink()], duration: nil,
                warnOnSilence: false)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }
        return finished
    }

    /// Feeds IO cycles every 20 ms for `seconds`.
    private func feed(_ session: TapStubSession, tapSilent: Bool, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            session.cycle(tapSilent: tapSilent)
            usleep(20_000)
        }
    }

    /// Zeros on the tap while a fresh tap hears audio: the engine rebuilds the
    /// tap, keeps recording, and the control reports the episode.
    @Test func zerosWithAudibleProbeRebuildTheTap() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.3)
        #expect(control.callAudio?.state == .ok)
        feed(session, tapSilent: true, seconds: 3.5)
        #expect(session.restartCount >= 1)
        #expect(control.callAudio?.state == .dead)
        feed(session, tapSilent: false, seconds: 0.2)
        #expect(control.callAudio?.state == .recovered)
        #expect(control.callAudio?.restarts == session.restartCount)
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)  // still recording

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// A probe that can't be built is not evidence of anything: no rebuild.
    @Test func failedProbeNeverRebuilds() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.failed("no tap"))
        let finished = start(session, control)

        feed(session, tapSilent: true, seconds: 3.5)
        #expect(session.probeCount >= 1)
        #expect(session.restartCount == 0)
        #expect(control.callAudio?.state == .silent)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// Paused: zeros with an audible probe would be a dead tap, but a paused
    /// recording is left alone. Resuming arms it again.
    @Test func pausedRecordingIsNeitherProbedNorRebuilt() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.2)
        control.pause()
        feed(session, tapSilent: true, seconds: 3.5)
        #expect(session.probeCount == 0)
        #expect(session.restartCount == 0)
        control.resume()
        feed(session, tapSilent: true, seconds: 3.5)
        #expect(session.restartCount >= 1)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// Buffers stop arriving altogether: the stall watchdog rebuilds the tap and
    /// the tap monitor stays out of it (no probe, no second rebuild).
    @Test func stalledStreamIsLeftToTheStallWatchdog() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        let finished = start(session, control, stallSeconds: 0.5)

        feed(session, tapSilent: true, seconds: 0.3)
        usleep(5_000_000)  // no cycles at all; stall retries every 3 s
        #expect(session.restartCount >= 1)  // the stall watchdog's
        #expect(session.restartCount <= 2)
        #expect(session.probeCount == 0)
        #expect(control.callAudio?.restarts == 0)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// A stop that lands while a rebuild is running waits for it, so `stop()`
    /// never runs under a `restart()` that would re-create the tap after it.
    @Test func stopWaitsForARunningRebuild() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        session.setRestartSeconds(1.0)
        let finished = start(session, control)

        let deadline = Date().addingTimeInterval(6)
        while !session.isRestarting, Date() < deadline { session.cycle(tapSilent: true); usleep(20_000) }
        #expect(session.isRestarting)
        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(!session.stoppedDuringRestart)
    }

    /// Zeros on the tap and the probe hears nothing either: a quiet room. The
    /// tap is probed but never rebuilt.
    @Test func zerosWithQuietProbeLeaveTheTapAlone() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.silent)
        let finished = start(session, control)

        feed(session, tapSilent: true, seconds: 3.5)
        #expect(session.probeCount >= 1)
        #expect(session.restartCount == 0)
        #expect(control.callAudio?.state == .silent)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }
}

@Suite("Call audio status")
struct CallAudioStatusTests {
    @Test func snapshotIsLiveWhileRunningAndFrozenAtFinish() throws {
        let manager = RemoteSessionManager()
        let control = CaptureControl()
        _ = try manager.begin(
            id: "a", control: control, hasMic: true, muted: false, audio: "a.wav", transcript: nil)
        #expect(manager.current()?.callAudio == nil)  // capture doesn't monitor (yet)

        let status = UncheckedSendableBox(
            value: TapSilenceMonitor.Status(state: .silent, silentFor: 12.34, restarts: 0))
        control.setCallAudioSource { status.value }
        #expect(manager.current()?.callAudio?.state == .silent)

        manager.finish(id: "a", error: nil)
        #expect(manager.current()?.callAudio == status.value)
    }

    @Test func statusJSONCarriesCallAudioAndKeepsExistingFields() throws {
        var snap = RemoteSessionManager.Snapshot(
            id: "a", state: .recording, startedAt: Date(), audio: "a.wav", transcript: nil,
            hasMic: true, muted: false, error: nil)
        snap.callAudio = .init(state: .dead, silentFor: 12.34, restarts: 2)
        let data = try JSONEncoder().encode(
            StatusResponse(version: "v", address: "127.0.0.1:1", session: snap))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["id"] as? String == "a")
        #expect(session["state"] as? String == "recording")
        #expect(session["muted"] as? Bool == false)
        #expect(session["audio"] as? String == "a.wav")
        let callAudio = try #require(session["callAudio"] as? [String: Any])
        #expect(callAudio["state"] as? String == "dead")
        #expect(callAudio["silentFor"] as? Double == 12.3)
        #expect(callAudio["restarts"] as? Int == 2)

        snap.callAudio = nil  // mic-only capture: the key is absent, not null
        let bare = try JSONEncoder().encode(
            StatusResponse(version: "v", address: "127.0.0.1:1", session: snap))
        #expect(!String(decoding: bare, as: UTF8.self).contains("callAudio"))
    }
}
