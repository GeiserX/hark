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

    /// A monitor whose tap has already delivered audio once, which is what arms
    /// it: a tap that has never been heard is never judged. The test about that
    /// gate builds its monitor directly instead.
    private func monitor(_ clock: Clock, maxRestarts: Int = 5) -> TapSilenceMonitor {
        let monitor = TapSilenceMonitor(
            silenceSeconds: 10, confirmSeconds: 0.5, maxRestarts: maxRestarts, now: clock.now)
        monitor.observe(silent: false)
        return monitor
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

    /// The missing "System Audio Recording" grant: the tap delivers zeros from
    /// its very first cycle while the mic keeps the buffers coming. A tap that
    /// was never alive is not a tap that died — judging it would build and tear
    /// down a probe tap every minute for the whole recording, on exactly the
    /// path where that teardown has been seen to wedge. So one non-silent cycle
    /// has to arrive before any zero run counts.
    @Test func aTapThatNeverDeliveredAudioIsNeverJudged() {
        let clock = Clock()
        let m = TapSilenceMonitor(
            silenceSeconds: 10, confirmSeconds: 0.5, maxRestarts: 5, now: clock.now)
        for _ in 0..<300 {
            m.observe(silent: true)
            clock.t += 1
            #expect(m.tick() == .none)
        }
        #expect(m.status() == .init(state: .ok, silentFor: 0, restarts: 0))

        // One non-silent cycle arms it, and the zero run starts from there.
        m.observe(silent: false)
        zeros(m, clock, seconds: 9)
        #expect(m.tick() == .none)
        zeros(m, clock, seconds: 1)
        #expect(m.tick() == .probe)
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
    private var probeSeconds = 0.0
    private var probing = false
    private var restartSeconds = 0.0
    private var stopSeconds = 0.0
    private var stopDone = false
    private var restarting = false
    private var restartBegan: Date?
    private(set) var stoppedDuringRestart = false
    var onTapActivity: (@Sendable (_ silent: Bool) -> Void)?
    /// Mirrors `SystemCaptureSession`: whether the tap can be monitored at all
    /// depends on the stream format, which is only read inside `start`, so the
    /// answer may change there.
    private let tapActivityBeforeStart: Bool
    private let tapActivityAfterStart: Bool
    var reportsTapActivity: Bool { isReady ? tapActivityAfterStart : tapActivityBeforeStart }
    let tapDiagnostics = "stub tap"

    init(reportsTapActivity: Bool = true, afterStart: Bool? = nil) {
        tapActivityBeforeStart = reportsTapActivity
        tapActivityAfterStart = afterStart ?? reportsTapActivity
    }

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {
        lock.lock()
        if restarting { stoppedDuringRestart = true }
        let hold = stopSeconds
        lock.unlock()
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        lock.lock(); stopDone = true; lock.unlock()
    }
    func restart() -> Bool {
        lock.lock()
        restarts += 1
        restarting = true
        restartBegan = Date()
        let hold = restartSeconds
        lock.unlock()
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        lock.lock(); restarting = false; lock.unlock()
        return true
    }
    var isRestarting: Bool { lock.lock(); defer { lock.unlock() }; return restarting }
    /// When the current (or last) `restart()` began, so a test can tell how much
    /// of the hold was still to run when the stop landed.
    var restartBeganAt: Date? { lock.lock(); defer { lock.unlock() }; return restartBegan }
    func setRestartSeconds(_ value: Double) { lock.lock(); restartSeconds = value; lock.unlock() }
    func setStopSeconds(_ value: Double) { lock.lock(); stopSeconds = value; lock.unlock() }
    /// True once `stop()` ran to completion — false if the teardown budget ran
    /// out while it was still working.
    var stopFinished: Bool { lock.lock(); defer { lock.unlock() }; return stopDone }
    func probeTap(maxSeconds: Double) -> TapProbeResult {
        lock.lock()
        probes += 1
        probing = true
        let hold = probeSeconds
        let answer = probeAnswer
        lock.unlock()
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        lock.lock(); probing = false; lock.unlock()
        return answer
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    var restartCount: Int { lock.lock(); defer { lock.unlock() }; return restarts }
    var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
    func setProbeResult(_ value: TapProbeResult) { lock.lock(); probeAnswer = value; lock.unlock() }
    func setProbeSeconds(_ value: Double) { lock.lock(); probeSeconds = value; lock.unlock() }
    /// True while a `probeTap` call is in flight — a throwaway tap on the live
    /// capture's scope.
    var isProbing: Bool { lock.lock(); defer { lock.unlock() }; return probing }
    /// One IO cycle: the mic keeps the buffers coming either way. Tap silence is
    /// reported only when this session reports tap activity at all, as the real
    /// session's IO callback does.
    func cycle(tapSilent: Bool) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(Data(repeating: 1, count: 320))
        if reportsTapActivity { onTapActivity?(tapSilent) }
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

    /// Runs the engine against `session` on its own thread and returns once the
    /// capture is live.
    ///
    /// `tapSilenceSeconds` is 2 rather than the shortest window that works,
    /// because it also sets the monitor's stale window (`min(2, …)`): with 0.5 s
    /// a `feed` thread descheduled for half a second on a loaded runner abandons
    /// the zero run and the assertions fail for a reason the test isn't about.
    private func start(
        _ session: TapStubSession, _ control: CaptureControl, stallSeconds: Double = 3,
        tapSilenceSeconds: Double = 2
    ) -> DispatchSemaphore {
        var eng = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        eng.control = control
        eng.recovery = RecoverySettings(
            enabled: true, stallSeconds: stallSeconds, giveUpSeconds: 0,
            tapSilenceSeconds: tapSilenceSeconds)
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
        feed(session, tapSilent: true, seconds: 5)
        #expect(session.restartCount >= 1)
        #expect(control.callAudio?.state == .dead)
        feed(session, tapSilent: false, seconds: 0.2)
        #expect(control.callAudio?.state == .recovered)
        #expect(control.callAudio?.restarts == session.restartCount)
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)  // still recording

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// A tap stream that turns out not to be 32-bit float can't be judged by
    /// `TapLevel`, and the session only knows that once `start` has built the
    /// aggregate. The capture runs, and `callAudio` is absent rather than
    /// reporting an "ok" nothing ever measured.
    @Test func aTapStreamThatCannotBeJudgedIsNotAdvertised() {
        let control = CaptureControl()
        let session = TapStubSession(reportsTapActivity: true, afterStart: false)
        session.setProbeResult(.heardAudio)
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.3)
        feed(session, tapSilent: true, seconds: 4)
        #expect(control.callAudio == nil)
        #expect(session.probeCount == 0)
        #expect(session.restartCount == 0)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// The missing-grant case end to end: the tap is silent from its first cycle,
    /// so the engine never builds a probe tap for it, however long it runs.
    @Test func aTapSilentFromTheFirstCycleIsNeverProbed() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        let finished = start(session, control)

        feed(session, tapSilent: true, seconds: 5)
        #expect(session.probeCount == 0)
        #expect(session.restartCount == 0)
        #expect(control.callAudio?.state == .ok)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// A probe that can't be built is not evidence of anything: no rebuild.
    @Test func failedProbeNeverRebuilds() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.failed("no tap"))
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        feed(session, tapSilent: true, seconds: 4)
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
        feed(session, tapSilent: true, seconds: 6)
        #expect(session.restartCount >= 1)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// Buffers stop arriving altogether: the stall watchdog rebuilds the tap and
    /// the tap monitor stays out of it (no probe, no rebuild of its own).
    ///
    /// A 4 s tap-silence window with the stale window still at `min(2, …)` = 2 s
    /// is what makes that deterministic: a tick between 2.6 s and 4 s after the
    /// last cycle sees a stale run and abandons it, and the 1 s cadence puts at
    /// least one tick in that window. How many times the stall watchdog manages
    /// to retry in 5 s is not this test's claim — `probeCount` and the monitor's
    /// own `restarts` are.
    @Test func stalledStreamIsLeftToTheStallWatchdog() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        let finished = start(session, control, stallSeconds: 0.5, tapSilenceSeconds: 4)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        feed(session, tapSilent: true, seconds: 0.3)
        usleep(5_000_000)  // no cycles at all; stall retries every 3 s
        #expect(session.restartCount >= 1)  // the stall watchdog's
        #expect(session.probeCount == 0)
        #expect(control.callAudio?.restarts == 0)

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    /// A stop that lands while a rebuild is running waits for it, so `stop()`
    /// never runs under a `restart()` that would re-create the tap after it.
    ///
    /// `stoppedDuringRestart` alone can't carry that: with a rebuild short
    /// enough to finish on its own it stays false whether the drain exists or
    /// not. So the rebuild holds for 3 s and the test also measures the wall
    /// time from `stop()` to the run finishing — without the drain the stop
    /// returns at once and that time is near zero.
    @Test func stopWaitsForARunningRebuild() throws {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        session.setRestartSeconds(3.0)
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        let deadline = Date().addingTimeInterval(15)
        while !session.isRestarting, Date() < deadline { session.cycle(tapSilent: true); usleep(20_000) }
        #expect(session.isRestarting)
        let began = try #require(session.restartBeganAt)
        control.stop()
        let stoppedAt = Date()
        #expect(finished.wait(timeout: .now() + 15) == .success)
        let waited = Date().timeIntervalSince(stoppedAt)
        let holdLeft = 3.0 - stoppedAt.timeIntervalSince(began)
        #expect(holdLeft > 1)  // the rebuild really was still running
        #expect(waited >= holdLeft - 0.2)
        #expect(!session.stoppedDuringRestart)
    }

    /// The stop has a teardown budget of its own. A rebuild still running when
    /// the stop lands is drained under its own bound first, so a slow stop is
    /// not cut short by however long the rebuild took — which would also print
    /// the missing-grant advice for a cause that has nothing to do with TCC.
    @Test func aSlowRebuildDoesNotEatTheStopsTeardownBudget() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.heardAudio)
        session.setRestartSeconds(3.0)
        session.setStopSeconds(3.5)  // 3 + 3.5 is over the 5 s teardown budget
        let finished = start(session, control, stallSeconds: 60)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        let deadline = Date().addingTimeInterval(15)
        while !session.isRestarting, Date() < deadline {
            session.cycle(tapSilent: true)
            usleep(20_000)
        }
        #expect(session.isRestarting)
        control.stop()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(session.stopFinished)
    }

    /// A tap check still running when the stop lands is waited for. That check
    /// holds a second tap on the live capture's scope, and the agent may already
    /// be configuring the next capture by the time the run returns.
    @Test func stopWaitsForARunningTapCheck() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.silent)  // a quiet room: a check, never a rebuild
        session.setProbeSeconds(2)
        let finished = start(session, control, stallSeconds: 60)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        let deadline = Date().addingTimeInterval(15)
        while !session.isProbing, Date() < deadline {
            session.cycle(tapSilent: true)
            usleep(20_000)
        }
        #expect(session.isProbing)
        control.stop()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(!session.isProbing)
    }

    /// Zeros on the tap and the probe hears nothing either: a quiet room. The
    /// tap is probed but never rebuilt.
    @Test func zerosWithQuietProbeLeaveTheTapAlone() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeResult(.silent)
        let finished = start(session, control)

        feed(session, tapSilent: false, seconds: 0.3)  // the tap was alive first
        feed(session, tapSilent: true, seconds: 4)
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
