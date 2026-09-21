import Encoders
import Foundation

/// A live transcription sink: an `AudioSink` that also carries a deferred
/// transcription error out to the CLI after capture finishes. Both live paths
/// (segmented and streaming) satisfy it, so `Hark.executeLive` picks one and the
/// rest of the wiring is identical.
protocol LiveTranscriptionSink: AudioSink {
    func rethrowErrors() throws
}

extension LiveTranscriber: LiveTranscriptionSink {}

/// Continuous live transcription (`--live-streaming`): instead of waiting for a
/// pause and transcribing one finished window, the whole capture is streamed
/// through a chunked recognizer and the growing token list is cut into transcript
/// lines in hark.
///
/// What the user sees: text about one chunk (2.24 s) behind the audio instead of
/// 9 to 12 s, and an open line that grows in place until a pause closes it. The
/// closed lines land in the same append-only `LiveTranscriptWriter` the segmented
/// path uses, so the transcript file format does not change.
///
/// Shape follows `VadSegmenter`: `write` runs on the capture I/O queue and only
/// counts bytes and yields into an unbounded `AsyncStream`; one consumer `Task`
/// owns every piece of mutable decoding state, so there are no locks on the
/// decode path. One resampler serves the whole call, so the recognizer's sample
/// clock and hark's capture clock are the same quantity (`CaptureEngine` drops
/// paused chunks before any sink, so both exclude paused time).
final class StreamingLiveTranscriber: LiveTranscriptionSink, @unchecked Sendable {
    private let recognizer: any StreamingRecognizer
    private let writer: LiveTranscriptWriter
    private let ownsWriter: Bool
    private let speaker: String?
    private let resolver: LiveSpeakerResolver?
    private let captureFormat: PCMFormat
    private let control: CaptureControl?
    private let sourceKey: String
    private let screenEcho: Bool
    private let screen: FileHandle
    private let transcriptLog: TranscriptLog?

    let label: String

    private let continuation: AsyncStream<Data>.Continuation
    private let done = DispatchSemaphore(value: 0)
    private let failure = FailureBox()
    private let lock = NSLock()
    private var totalBytes: UInt64 = 0
    private var pendingBytes: Int = 0
    private var finished = false
    private var task: Task<Void, Never>? = nil

    // Owned exclusively by the consumer Task (no locks).
    private var cutter: StreamingLineCutter
    private let resampler: StreamResampler
    private var pushedSamples = 0
    private var decodeStopped = false
    private var backlogReported = false

    /// How far captured audio may run ahead of the decoder before it is worth a
    /// notice. Audio is never dropped; a slow decoder only delays the text.
    private static let backlogNoticeSeconds: Double = 30

    init(
        recognizer: any StreamingRecognizer,
        writer: LiveTranscriptWriter,
        ownsWriter: Bool,
        speaker: String?,
        resolver: LiveSpeakerResolver?,
        captureFormat: PCMFormat,
        control: CaptureControl?,
        sourceKey: String,
        gapSeconds: Double,
        maxLineSeconds: Double,
        labelName: String,
        screenEcho: Bool = false,
        screen: FileHandle = .standardOutput,
        transcriptLog: TranscriptLog? = nil
    ) {
        self.recognizer = recognizer
        self.writer = writer
        self.ownsWriter = ownsWriter
        self.speaker = speaker
        self.resolver = resolver
        self.captureFormat = captureFormat
        self.control = control
        self.sourceKey = sourceKey
        self.screenEcho = screenEcho
        self.screen = screen
        self.transcriptLog = transcriptLog
        self.label = labelName
        self.cutter = StreamingLineCutter(
            gapSeconds: gapSeconds, maxLineSeconds: maxLineSeconds)
        // One continuous resampler for the whole call: per-chunk resampling drifts
        // against the capture clock, which would misplace every timestamp. Same
        // construction as the VAD path (`SpeechSegmenterFactory.make`) — identity
        // at 16 kHz, since `unpackMono` has already folded the channels.
        var resampler: StreamResampler = IdentityResampler()
        if captureFormat.sampleRate != 16000,
            let streaming = AVStreamResampler(inputRate: Double(captureFormat.sampleRate))
        {
            resampler = streaming
        }
        self.resampler = resampler

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.task = Task { [self] in
            for await data in stream { await consume(data) }
            await drain()
            done.signal()
        }
        Log.verbose("""
            live transcription: streaming (nemotron multilingual \(NemotronStreamingModels.bundle))\
            \(speaker.map { " [\($0)]" } ?? ""); line gap \(gapSeconds)s, cap \(maxLineSeconds)s
            """)
    }

    // MARK: AudioSink

    func write(_ data: Data) throws {
        // A stored transcript-write error is terminal: stop feeding the decoder,
        // exactly as the segmented path stops transcribing. `rethrowErrors`
        // surfaces it once capture ends.
        guard failure.take() == nil else { return }
        lock.lock()
        totalBytes += UInt64(data.count)
        pendingBytes += data.count
        lock.unlock()
        continuation.yield(data)
    }

    func finalize() throws {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        continuation.finish()
        done.wait()
    }

    /// Async variant of `finalize()` for callers already inside the Swift
    /// concurrency runtime (unit tests): awaits the consumer `Task` instead of
    /// blocking a cooperative thread on the semaphore, which would deadlock the
    /// very Task it waits for on a core-constrained host.
    func finalizeAsync() async {
        let already = lock.withLock { () -> Bool in
            defer { finished = true }
            return finished
        }
        guard !already else { return }
        continuation.finish()
        await task?.value
    }

    var bytesWritten: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    /// Surfaces a stored transcript-write error after capture finishes. A closed
    /// downstream pipe is graceful completion, as in `LiveTranscriber`.
    func rethrowErrors() throws {
        guard let error = failure.take() else { return }
        if isBrokenPipe(error) {
            Log.verbose("transcript pipe closed, stopping")
            return
        }
        throw error
    }

    // MARK: Consumer (single Task)

    private func consume(_ data: Data) async {
        let backlog = lock.withLock { () -> Double in
            pendingBytes -= data.count
            return Double(pendingBytes) / Double(max(1, captureFormat.byteRate))
        }
        if backlog >= Self.backlogNoticeSeconds, !backlogReported {
            backlogReported = true
            Log.notice("""
                live streaming transcription is \(Int(backlog))s behind the audio; \
                the recording is unaffected and the text catches up
                """)
        }
        guard !decodeStopped, !data.isEmpty else { return }
        let mono = VadSegmenter.unpackMono(data, format: captureFormat)
        let resampled = resampler.resample(mono)
        guard !resampled.isEmpty else { return }
        await feed(resampled)
    }

    private func drain() async {
        if !decodeStopped {
            let tail = resampler.flush()
            if !tail.isEmpty { await feed(tail) }
            do {
                let all = try await recognizer.finish()
                for range in cutter.cut(tokens: all, processedSeconds: .infinity) {
                    emit(all, range)
                }
            } catch {
                Log.verbose("streaming transcription failed to flush its tail: \(error)")
            }
        }
        control?.setPartial(nil, for: sourceKey)
        if ownsWriter { try? writer.close() }
    }

    /// Feeds 16 kHz mono samples to the recognizer, closes whatever lines that
    /// completed, and republishes the open line.
    private func feed(_ samples: [Float]) async {
        pushedSamples += samples.count
        let tokens: [RecognizedToken]
        do {
            tokens = try await recognizer.process(samples)
        } catch {
            // A decode failure costs the transcript from here on, never the
            // recording: stop feeding, keep capturing.
            Log.notice(
                "live streaming transcription stopped after a decode error; the recording continues")
            Log.verbose("streaming decode error: \(error)")
            decodeStopped = true
            control?.setPartial(nil, for: sourceKey)
            return
        }
        for range in cutter.cut(tokens: tokens, processedSeconds: processedSeconds()) {
            emit(tokens, range)
        }
        publishPartial(tokens)
    }

    /// Seconds of audio the recognizer has actually decoded. Exact, because
    /// `process` only drains whole chunks counted from sample zero.
    private func processedSeconds() -> Double {
        let chunk = recognizer.chunkSamples
        guard chunk > 0 else { return Double(pushedSamples) / 16000 }
        return Double((pushedSamples / chunk) * chunk) / 16000
    }

    /// Writes one closed line to the transcript (and the interactive surfaces).
    private func emit(_ tokens: [RecognizedToken], _ range: Range<Int>) {
        let line = SentencePieceText.trimmingLeadingPunctuation(tokens[range])
        guard let first = line.first, let last = line.last else { return }
        let text = SentencePieceText.join(line)
        guard !text.isEmpty else { return }
        let start = first.start
        let end = last.end
        let who = resolver?.label(start: start, end: end) ?? speaker
        do {
            try writer.append(text: text, start: start, end: end, speaker: who)
        } catch {
            // A failed transcript write is terminal, exactly as in the segmented
            // path: record it so capture stops cleanly.
            _ = failure.store(error)
            return
        }
        let caption = (who.map { "\($0): " } ?? "") + text
        transcriptLog?.append(caption)
        if screenEcho {
            try? screen.write(contentsOf: Data((caption + "\n").utf8))
        }
    }

    /// Publishes the open line for `GET /status`, or clears it when nothing is
    /// pending.
    private func publishPartial(_ tokens: [RecognizedToken]) {
        guard let control else { return }
        let finalized = cutter.finalized
        guard finalized < tokens.count else {
            control.setPartial(nil, for: sourceKey)
            return
        }
        // Same leading-punctuation trim as a closed line, so the viewer never
        // shows a line that opens with a stray period.
        let open = SentencePieceText.trimmingLeadingPunctuation(tokens[finalized...])
        let text = SentencePieceText.join(open)
        guard let first = open.first, let last = open.last, !text.isEmpty else {
            control.setPartial(nil, for: sourceKey)
            return
        }
        let start = first.start
        let who = resolver?.label(start: start, end: last.end) ?? speaker
        control.setPartial(
            PartialLine(text: text, start: start, speaker: who), for: sourceKey)
    }
}
