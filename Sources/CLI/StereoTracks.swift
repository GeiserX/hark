import ArgumentParser
import Encoders
import Foundation
import TapEngine

/// How the two captured sources are laid out in the `-a` audio file
/// (`--tracks`, PRD §6.7d).
enum TrackLayout: String, CaseIterable, ExpressibleByArgument {
    /// One summed stream: every channel carries mic + system audio.
    case mixed
    /// The microphone on channel 0 (left), the system/app audio on channel 1
    /// (right), in the same single file.
    case stereo
}

/// Folds two same-format packed-PCM buffers to mono and interleaves them into
/// one **two-channel** buffer: `left` on channel 0, `right` on channel 1. The
/// counterpart of `StreamMixing.sum`, which sums the same two buffers instead.
///
/// Both sides arrive upmixed to the capture layout (`StreamMixer` duplicates a
/// mono mic across the tap's channels), so each is folded by averaging its own
/// channels — recovering a mono mic exactly, and downmixing genuinely stereo
/// system audio rather than dropping half of it. Averaging cannot clip, so
/// unlike summing this needs no clamping. Only the common prefix is converted;
/// a trailing partial frame on either side is ignored.
func interleaveAsStereo(left: Data, right: Data, format: PCMFormat) -> Data {
    let width = format.bitsPerSample / 8
    let channels = max(1, format.channels)
    let frameSize = channels * width
    let frames = min(left.count, right.count) / frameSize
    guard frames > 0 else { return Data() }

    var out = Data(count: frames * 2 * width)
    left.withUnsafeBytes { pl in
        right.withUnsafeBytes { pr in
            out.withUnsafeMutableBytes { po in
                switch format.bitsPerSample {
                case 16:
                    let sl = pl.bindMemory(to: Int16.self)
                    let sr = pr.bindMemory(to: Int16.self)
                    let so = po.bindMemory(to: Int16.self)
                    for frame in 0..<frames {
                        var l: Int32 = 0
                        var r: Int32 = 0
                        for channel in 0..<channels {
                            l += Int32(sl[frame * channels + channel])
                            r += Int32(sr[frame * channels + channel])
                        }
                        so[frame * 2] = Int16(l / Int32(channels))
                        so[frame * 2 + 1] = Int16(r / Int32(channels))
                    }
                case 32:
                    let sl = pl.bindMemory(to: Int32.self)
                    let sr = pr.bindMemory(to: Int32.self)
                    let so = po.bindMemory(to: Int32.self)
                    for frame in 0..<frames {
                        var l: Int64 = 0
                        var r: Int64 = 0
                        for channel in 0..<channels {
                            l += Int64(sl[frame * channels + channel])
                            r += Int64(sr[frame * channels + channel])
                        }
                        so[frame * 2] = Int32(l / Int64(channels))
                        so[frame * 2 + 1] = Int32(r / Int64(channels))
                    }
                case 24:
                    // 3-byte little-endian samples.
                    func read(_ p: UnsafeRawBufferPointer, _ base: Int) -> Int32 {
                        let v = UInt32(p[base]) | UInt32(p[base + 1]) << 8 | UInt32(p[base + 2]) << 16
                        return Int32(bitPattern: (v & 0x80_0000) != 0 ? v | 0xFF00_0000 : v)
                    }
                    func write(_ p: UnsafeMutableRawBufferPointer, _ base: Int, _ value: Int32) {
                        let u = UInt32(bitPattern: value)
                        p[base] = UInt8(u & 0xFF)
                        p[base + 1] = UInt8((u >> 8) & 0xFF)
                        p[base + 2] = UInt8((u >> 16) & 0xFF)
                    }
                    for frame in 0..<frames {
                        var l: Int32 = 0
                        var r: Int32 = 0
                        for channel in 0..<channels {
                            let base = (frame * channels + channel) * 3
                            l += read(pl, base)
                            r += read(pr, base)
                        }
                        write(po, frame * 6, l / Int32(channels))
                        write(po, frame * 6 + 3, r / Int32(channels))
                    }
                default:
                    break  // unreachable: --bits is validated to 16/24/32
                }
            }
        }
    }
    return out
}

/// Writes both capture sources into one interleaved two-channel file for
/// `--tracks stereo`: the microphone on the left, the system/app audio on the
/// right (PRD §6.7d).
///
/// The sources arrive as two independent callbacks, so this buffers both and
/// converts only their **common prefix** — the same shape as the summing
/// `drainMix` in `ScreenCaptureSession`. The unmatched tail stays buffered and
/// is dropped at finalize: at most one chunk on one channel, exactly what the
/// mixed stream already drops there.
///
/// Feed it through `trackSinks()`: `CaptureEngine` filters per-source chunks by
/// tag and then calls the bare `AudioSink.write`, so a sink cannot tell which
/// source it got and each side needs its own tagged adapter.
final class StereoTrackWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: AudioSink
    private let format: PCMFormat
    private let pauseGeneration: @Sendable () -> UInt64
    private var micQueue = Data()
    private var systemQueue = Data()
    private var lastPauseGeneration: UInt64
    private var finalized = false

    /// - Parameters:
    ///   - sink: the `-a` sink; it receives the interleaved two-channel stream.
    ///   - format: the capture format (drives the frame size; `channels` is 2).
    ///   - pauseGeneration: the capture's pause counter — see `write`.
    init(
        sink: AudioSink, format: PCMFormat,
        pauseGeneration: @escaping @Sendable () -> UInt64 = { 0 }
    ) {
        self.sink = sink
        self.format = format
        self.pauseGeneration = pauseGeneration
        self.lastPauseGeneration = pauseGeneration()
    }

    /// The tagged adapters to hand `CaptureEngine.run` as its `sourceSinks`.
    func trackSinks() -> [(CaptureSource, AudioSink)] {
        [
            (.microphone, TrackSink(source: .microphone, writer: self)),
            (.system, TrackSink(source: .system, writer: self)),
        ]
    }

    /// Buffers one source's chunk and emits whatever now pairs up.
    ///
    /// Pause is applied per chunk on the capture IO queue, so it can land
    /// *between* the two sources of the same instant: one side's chunk is kept
    /// and the other's dropped, which would offset left from right for the rest
    /// of the recording. The pause counter makes that recoverable — on the first
    /// chunk after a pause both still-unpaired tails are dropped, so the two
    /// channels resume aligned instead of carrying the offset forever. The
    /// discarded tails are audio the pause was gapping anyway.
    func write(_ data: Data, from source: CaptureSource) throws {
        let paired: Data
        lock.lock()
        let generation = pauseGeneration()
        if generation != lastPauseGeneration {
            lastPauseGeneration = generation
            micQueue.removeAll(keepingCapacity: true)
            systemQueue.removeAll(keepingCapacity: true)
        }
        switch source {
        case .microphone: micQueue.append(data)
        case .system: systemQueue.append(data)
        }
        let frameSize = max(1, format.bytesPerFrame)
        let common = min(micQueue.count, systemQueue.count) / frameSize * frameSize
        guard common > 0 else {
            lock.unlock()
            return
        }
        paired = interleaveAsStereo(
            left: Data(micQueue.prefix(common)), right: Data(systemQueue.prefix(common)),
            format: format)
        micQueue.removeFirst(common)
        systemQueue.removeFirst(common)
        lock.unlock()
        try sink.write(paired)
    }

    /// Finalizes the underlying sink once, however many adapters report in.
    func finalize() throws {
        lock.lock()
        let alreadyFinalized = finalized
        finalized = true
        lock.unlock()
        guard !alreadyFinalized else { return }
        try sink.finalize()
    }

    var bytesWritten: UInt64 { sink.bytesWritten }
    var label: String { sink.label }
}

/// One side of a `StereoTrackWriter`: an `AudioSink` that remembers which source
/// it is bound to, so the shared writer knows which channel a chunk belongs on.
///
/// It is a `RecordingSink`, not a plain per-source sink: what it writes is the
/// user's `-a` file, so a write that fails must end the capture with an error
/// the way the mixed stream's does, instead of being dropped as a best-effort
/// feed would be.
private final class TrackSink: RecordingSink, @unchecked Sendable {
    private let source: CaptureSource
    private let writer: StereoTrackWriter

    init(source: CaptureSource, writer: StereoTrackWriter) {
        self.source = source
        self.writer = writer
    }

    func write(_ data: Data) throws { try writer.write(data, from: source) }
    func finalize() throws { try writer.finalize() }
    var bytesWritten: UInt64 { writer.bytesWritten }
    var label: String { writer.label }
}
