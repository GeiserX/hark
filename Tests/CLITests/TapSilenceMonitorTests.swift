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
            m.observe(silent: true)
            clock.t += 9  // just under the threshold, like a pause between speakers
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
        m.observe(silent: true)
        clock.t += 10
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
        m.observe(silent: true)
        clock.t += 10
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
        m.observe(silent: true)
        clock.t += 10
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
        m.observe(silent: true)
        clock.t += 10
        #expect(m.tick() == .probe)
        m.observe(silent: false)  // audio back while the probe is still running
        m.observe(silent: true)  // a new run begins
        m.probeFinished(heardAudio: true)
        clock.t += 5
        #expect(m.tick() == .none)
        #expect(m.status().state == .ok)
        #expect(m.status().restarts == 0)
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
    private var probeAnswer = false
    var onTapActivity: (@Sendable (_ silent: Bool) -> Void)?
    let reportsTapActivity = true
    let tapDiagnostics = "stub tap"

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {}
    func restart() -> Bool {
        lock.lock(); restarts += 1; lock.unlock()
        return true
    }
    func probeTap(maxSeconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        probes += 1
        return probeAnswer
    }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    var restartCount: Int { lock.lock(); defer { lock.unlock() }; return restarts }
    var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
    func setProbeHearsAudio(_ value: Bool) { lock.lock(); probeAnswer = value; lock.unlock() }
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

    private func start(_ session: TapStubSession, _ control: CaptureControl) -> DispatchSemaphore {
        var eng = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: true, apps: [], excludeApps: [], mix: true)
        eng.control = control
        eng.recovery = RecoverySettings(
            enabled: true, stallSeconds: 3, giveUpSeconds: 0, tapSilenceSeconds: 0.5)
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
        session.setProbeHearsAudio(true)
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

    /// Zeros on the tap and the probe hears nothing either: a quiet room. The
    /// tap is probed but never rebuilt.
    @Test func zerosWithQuietProbeLeaveTheTapAlone() {
        let control = CaptureControl()
        let session = TapStubSession()
        session.setProbeHearsAudio(false)
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
