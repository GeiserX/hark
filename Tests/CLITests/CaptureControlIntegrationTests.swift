import Encoders
import Foundation
import TapEngine
import Testing

@testable import CLI

/// A controllable in-memory capture session: the test pushes PCM through the
/// stored `onAudio` callback and ends the run via the shared `CaptureControl`.
private final class StubSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }
    func stop() {}

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    func emit(_ data: Data) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(data)
    }
}

private final class CollectingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    let label = "collect"

    func write(_ data: Data) throws { lock.lock(); buffer.append(data); lock.unlock() }
    func finalize() throws {}
    var bytesWritten: UInt64 { lock.lock(); defer { lock.unlock() }; return UInt64(buffer.count) }
    func contains(byte: UInt8) -> Bool { lock.lock(); defer { lock.unlock() }; return buffer.contains(byte) }
}

@Suite("Capture pause drops audio (gap)", .serialized)
struct CaptureControlIntegrationTests {
    /// Paused capture must drop chunks entirely: the paused payload never
    /// reaches the sink (a true gap, and so `--split` never opens a new chunk
    /// while paused — PRD §10 Q10), while pre/post-pause audio is kept.
    @Test func pausedAudioIsDropped() throws {
        let control = CaptureControl()
        let session = StubSession()
        let sink = CollectingSink()
        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: false)
        engine.control = control

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, sink))
        Thread.detachNewThread {
            let (engine, session, sink) = box.value
            try? engine.run(
                session: session, format: format, into: [sink],
                duration: nil, warnOnSilence: false)
            finished.signal()
        }

        // Wait for run() to install the audio callback.
        while !session.isReady { usleep(1000) }

        session.emit(Data(repeating: 0x01, count: 320)); usleep(30_000)  // recorded
        control.pause(); usleep(10_000)
        session.emit(Data(repeating: 0x02, count: 320)); usleep(30_000)  // dropped (gap)
        control.resume(); usleep(10_000)
        session.emit(Data(repeating: 0x03, count: 320)); usleep(30_000)  // recorded

        control.stop()
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(!sink.contains(byte: 0x02))  // paused audio absent
        #expect(sink.contains(byte: 0x03))   // resumed audio present
        #expect(sink.bytesWritten == 640)    // 320 + 320 kept, 320 dropped
    }
}

/// A session whose `stop()` never returns — the shape of a Core Audio teardown
/// that can't reach the audio stream (a stale "System Audio Recording" grant).
private final class WedgedStopSession: CaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onAudio: (@Sendable (Data) -> Void)?
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func start(onAudio: @escaping @Sendable (Data) -> Void) throws {
        lock.lock(); self.onAudio = onAudio; lock.unlock()
    }

    func stop() {
        entered.signal()
        _ = release.wait(timeout: .now() + 30)  // freed at teardown of the test
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return onAudio != nil }
    func emit(_ data: Data) {
        lock.lock(); let cb = onAudio; lock.unlock()
        cb?(data)
    }
    func unwedge() { release.signal() }
}

@Suite("Bounded capture teardown", .serialized)
struct BoundedTeardownTests {
    /// A wedged `session.stop()` must not hold the recording hostage: capture
    /// finalizes anyway, so the audio captured so far is written and playable.
    @Test func wedgedStopStillFinalizesTheRecording() throws {
        let control = CaptureControl()
        let session = WedgedStopSession()
        let sink = CollectingSink()
        let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)
        var engine = CaptureEngine(
            deviceUID: nil, rate: 16000, bits: 16, channels: 1,
            captureSystem: false, apps: [], excludeApps: [], mix: false)
        engine.control = control
        engine.teardownTimeout = 0.3
        defer { session.unwedge() }

        let finished = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(value: (engine, session, sink))
        Thread.detachNewThread {
            let (engine, session, sink) = box.value
            try? engine.run(
                session: session, format: format, into: [sink],
                duration: nil, warnOnSilence: false)
            finished.signal()
        }
        while !session.isReady { usleep(1000) }
        session.emit(Data(repeating: 0x07, count: 320))
        usleep(30_000)
        control.stop()

        // run() returns despite stop() still being stuck, and keeps the audio.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(session.entered.wait(timeout: .now() + 1) == .success)
        #expect(sink.bytesWritten == 320)
    }

    @Test func runBoundedReportsWhetherWorkFinished() {
        #expect(CaptureEngine.runBounded(1, label: "fast") {})
        #expect(!CaptureEngine.runBounded(0.15, label: "slow") { Thread.sleep(forTimeInterval: 1) })
        // 0 keeps the old behavior: run inline, wait as long as it takes.
        let ran = LockBox<Bool>()
        #expect(CaptureEngine.runBounded(0, label: "inline") { ran.set(true) })
        #expect(ran.get() == true)
    }
}
