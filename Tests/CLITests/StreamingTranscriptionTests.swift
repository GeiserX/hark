import Encoders
import Foundation
import Testing

@testable import CLI

/// One transcript line as written by `LiveTranscriptWriter` in JSON-lines form.
private struct TranscriptLine: Decodable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
}

private func readLines(_ path: String) throws -> [TranscriptLine] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try JSONDecoder().decode(TranscriptLine.self, from: Data(trimmed.utf8))
    }
}

private func tempTranscriptPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hark-stream-\(UUID().uuidString).json").path
}

/// Token at `start` lasting one encoder frame (80 ms), like the real recognizer.
private func token(_ piece: String, _ start: Double) -> RecognizedToken {
    RecognizedToken(piece: piece, start: start, end: start + 0.08)
}

/// Seconds at an encoder-frame index, the way FluidAudio computes them: an exact
/// multiple of 0.08 with the rounding that implies. Tests about the gap floor have
/// to use this rather than literal seconds, or they test arithmetic the recognizer
/// never does.
private func frame(_ index: Int) -> Double {
    Double(index) * StreamingLineCutter.encoderFrameSeconds
}

/// A one-frame token starting at the given encoder-frame index.
private func frameToken(_ piece: String, _ index: Int) -> RecognizedToken {
    RecognizedToken(
        piece: piece, start: frame(index),
        end: frame(index) + StreamingLineCutter.encoderFrameSeconds)
}

/// Deterministic stand-in for the streaming ASR model: each scripted token
/// becomes visible once the given number of seconds has been fed, and the token
/// list only grows, the same contract the real recognizer has. Lets the sink's
/// line-cutting, transcript writing and partial publishing be tested without
/// CoreML and without audio.
private final class ScriptedStreamingRecognizer: StreamingRecognizer, @unchecked Sendable {
    let chunkSamples: Int
    private let script: [(available: Double, token: RecognizedToken)]
    private let lock = NSLock()
    private var pushed = 0

    init(chunkSamples: Int, script: [(available: Double, token: RecognizedToken)]) {
        self.chunkSamples = chunkSamples
        self.script = script
    }

    func process(_ samples: [Float]) async throws -> [RecognizedToken] {
        let seconds = lock.withLock { () -> Double in
            pushed += samples.count
            return Double(pushed) / 16000
        }
        return script.filter { $0.available <= seconds + 1e-9 }.map(\.token)
    }

    func finish() async throws -> [RecognizedToken] { script.map(\.token) }
}

/// A decoder that never answers, standing in for one wedged inside CoreML (or
/// simply minutes behind). `finalize()` has to give the recording back anyway.
private final class StalledStreamingRecognizer: StreamingRecognizer, @unchecked Sendable {
    let chunkSamples = 4000

    func process(_ samples: [Float]) async throws -> [RecognizedToken] {
        try await Task.sleep(for: .seconds(3600))
        return []
    }

    func finish() async throws -> [RecognizedToken] { [] }
}

/// A decoder that parks inside `process` until the test releases it, then answers
/// with one word. Models the real failure: `finalize()` gives up, the caller
/// reports the session finished, and only then does CoreML come back with words.
/// The park is a continuation resumed from another thread, so `Task.cancel()` does
/// not break it, exactly like a CoreML call that does not check for cancellation.
private final class ReleasableStreamingRecognizer: StreamingRecognizer, @unchecked Sendable {
    let chunkSamples = 4000
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var parked = false
    private var returned = false

    var hasParked: Bool { lock.withLock { parked } }
    var hasReturned: Bool { lock.withLock { returned } }

    func release() { gate.signal() }

    func process(_ samples: [Float]) async throws -> [RecognizedToken] {
        lock.withLock { parked = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.gate.wait()
                continuation.resume()
            }
        }
        lock.withLock { returned = true }
        return [token("\u{2581}late", 0.0)]
    }

    func finish() async throws -> [RecognizedToken] { [token("\u{2581}late", 0.0)] }
}

/// Holds a sink weakly so a test can watch it be deallocated. ARC's side table
/// makes the weak read safe from the polling closure; the box itself is never
/// mutated after the sink is dropped.
private final class WeakSinkBox: @unchecked Sendable {
    weak var sink: StreamingLiveTranscriber?
}

/// Fixed acoustic label, standing in for the live diarizer.
private final class FakeResolver: LiveSpeakerResolver, @unchecked Sendable {
    private let name: String
    init(_ name: String) { self.name = name }
    func label(start: Double, end: Double) -> String? { name }
}

@Suite("Streaming transcription (model-free)")
struct StreamingTranscriptionTests {
    private let captureFormat = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    /// 16 kHz mono 16-bit silence; the scripted recognizer ignores the content,
    /// only the sample count matters.
    private func silence(_ seconds: Double) -> Data {
        Data(count: Int(seconds * 16000) * 2)
    }

    // MARK: Detokenizer

    @Test func joinsSentencePiecePieces() {
        let tokens = [token("\u{2581}hola", 0), token("\u{2581}qué", 0.1), token("\u{2581}tal", 0.2)]
        #expect(SentencePieceText.join(tokens) == "hola qué tal")
    }

    /// The model emits a standalone word-boundary piece after sentence-final
    /// punctuation; naive detokenizing leaves a double space behind it.
    @Test func collapsesDoubleSpaceAfterPunctuation() {
        let tokens = [
            token("\u{2581}Sí", 0), token(".", 0.1), token("\u{2581}", 0.2),
            token("\u{2581}Vale", 0.3),
        ]
        let text = SentencePieceText.join(tokens)
        #expect(text == "Sí. Vale")
        #expect(!text.contains("  "))
    }

    @Test func recognizesPunctuationOnlyPieces() {
        #expect(SentencePieceText.isPunctuationOnly("."))
        #expect(SentencePieceText.isPunctuationOnly(","))
        #expect(SentencePieceText.isPunctuationOnly("\u{2581}"))
        #expect(SentencePieceText.isPunctuationOnly("\u{2581}?"))
        #expect(!SentencePieceText.isPunctuationOnly("\u{2581}Vale"))
        #expect(!SentencePieceText.isPunctuationOnly("2024"))
    }

    /// The recognizer emits a sentence's final period in the chunk after the pause
    /// that closed the line, so it arrives when the previous line is already
    /// written. Dropping it keeps the next line from opening with ". ".
    @Test func dropsPunctuationLeftOverFromThePreviousLine() {
        let tokens = [token(".", 5.76), token("\u{2581}Vamos", 5.84), token("\u{2581}ya", 5.92)]
        let trimmed = SentencePieceText.trimmingLeadingPunctuation(tokens[...])
        #expect(SentencePieceText.join(trimmed) == "Vamos ya")
        #expect(trimmed.first?.start == 5.84)
        // A line of nothing but punctuation has no words, so it is not a line.
        #expect(SentencePieceText.trimmingLeadingPunctuation([token(".", 1)][...]).isEmpty)
    }

    // MARK: Line cutter

    @Test func cutsOnAGapBetweenTokens() {
        var cutter = StreamingLineCutter(gapSeconds: 0.7, maxLineSeconds: 12)
        let tokens = [token("\u{2581}one", 0), token("\u{2581}two", 1.5)]
        #expect(cutter.cut(tokens: tokens, processedSeconds: 2.24) == [0..<1])
        #expect(cutter.finalized == 1)
    }

    @Test func cutsOnTrailingSilence() {
        var cutter = StreamingLineCutter(gapSeconds: 0.7, maxLineSeconds: 12)
        let tokens = [token("\u{2581}one", 0)]
        #expect(cutter.cut(tokens: tokens, processedSeconds: 2.24) == [0..<1])
        #expect(cutter.finalized == 1)
    }

    /// The decisive one: with nothing decoded yet, the same tokens must not close
    /// a line. A cutter driven by *fed* audio instead of *decoded* audio closes
    /// here and puts the rest of the line in the next one, behind it in time.
    @Test func doesNotCutBeforeTheAudioIsDecoded() {
        var cutter = StreamingLineCutter(gapSeconds: 0.7, maxLineSeconds: 12)
        let tokens = [token("\u{2581}one", 0)]
        #expect(cutter.cut(tokens: tokens, processedSeconds: 0) == [])
        #expect(cutter.finalized == 0)
    }

    /// `--segment-pause 0` is a legal setting, and tokens are one 80 ms encoder
    /// frame each with no space between them, so an unclamped gap of 0 finds a
    /// break between every adjacent pair and gives every token its own transcript
    /// line. Contiguous speech is one line, closed by the trailing silence.
    @Test func keepsContiguousTokensTogetherWhenThePauseIsZero() {
        var cutter = StreamingLineCutter(gapSeconds: 0, maxLineSeconds: 12)
        let tokens = [frameToken("\u{2581}one", 0), frameToken("\u{2581}two", 1), frameToken("\u{2581}three", 2)]
        // Decoded audio ends with the last token, so nothing has closed yet.
        #expect(cutter.cut(tokens: tokens, processedSeconds: frame(3)) == [])
        // The clamped pause of 1.5 frames closes the line, all three at once.
        #expect(cutter.cut(tokens: tokens, processedSeconds: frame(5)) == [0..<3])
        #expect(cutter.finalized == 3)
    }

    /// The floor has to sit strictly between one and two encoder frames, not on
    /// one.
    ///
    /// FluidAudio times tokens at exact multiples of 0.08, so two words with a
    /// single blank frame between them are exactly one frame apart, and in doubles
    /// that gap compares `>= 0.08` at some frame positions and `< 0.08` at others.
    /// A floor of one frame therefore broke the line at
    /// about two fifths of ordinary word boundaries, picked by where in the stream
    /// the words happened to fall. Frame indices here rather than literal seconds,
    /// so the arithmetic is the recognizer's own and the rounding is real.
    ///
    /// Frame 18 is one of the positions that compares `>=` on the old floor, so
    /// this goes red on it and green on 1.5 frames.
    @Test func oneBlankFrameBetweenWordsIsNotAPause() {
        var cutter = StreamingLineCutter(gapSeconds: 0, maxLineSeconds: 12)
        // "one" at frame 18, one blank frame, "two" at frame 20.
        let tokens = [frameToken("\u{2581}one", 18), frameToken("\u{2581}two", 20)]
        #expect(cutter.cut(tokens: tokens, processedSeconds: frame(21)) == [])
        #expect(cutter.finalized == 0)

        // Two blank frames is a real gap and still cuts, so the floor did not
        // simply stop the cutter working.
        var wider = StreamingLineCutter(gapSeconds: 0, maxLineSeconds: 12)
        let spaced = [frameToken("\u{2581}one", 18), frameToken("\u{2581}two", 21)]
        #expect(wider.cut(tokens: spaced, processedSeconds: frame(22)) == [0..<1])
        #expect(wider.finalized == 1)
    }

    /// Every frame position behaves the same way, which is the property the old
    /// floor did not have: on a one-frame floor this sweep reports 788 of the 2000
    /// positions cutting and 1212 not.
    @Test func noFramePositionTurnsOneBlankFrameIntoAPause() {
        for index in 0..<2000 {
            var cutter = StreamingLineCutter(gapSeconds: 0, maxLineSeconds: 12)
            let tokens = [frameToken("\u{2581}a", index), frameToken("\u{2581}b", index + 2)]
            #expect(
                cutter.cut(tokens: tokens, processedSeconds: frame(index + 3)) == [],
                "one blank frame cut the line at frame \(index)")
        }
    }

    @Test func cutsOnTheWindowCap() {
        var cutter = StreamingLineCutter(gapSeconds: 0.7, maxLineSeconds: 12)
        // A monologue: one token every 0.3 s for 13 s, so no gap ever reaches 0.7.
        var tokens: [RecognizedToken] = []
        var start = 0.0
        while start < 13 {
            tokens.append(token("\u{2581}word", start))
            start += 0.3
        }
        let cuts = cutter.cut(tokens: tokens, processedSeconds: 13.44)
        #expect(cuts.count == 1)
        #expect(cuts.first == 0..<tokens.count)
        #expect(cutter.finalized == tokens.count)
    }

    // MARK: Sink end to end

    /// Two lines separated by a pause, fed through `write` in 0.25 s slices, land
    /// in the transcript with the timings the script implies and the resolver's
    /// label.
    @Test func writesFinalizedLinesWithScriptedTimings() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recognizer = ScriptedStreamingRecognizer(
            chunkSamples: 4000,
            script: [
                (0.5, token("\u{2581}hello", 0.0)),
                (0.5, token("\u{2581}world", 0.08)),
                // The period for line 1 arrives after line 1 is already written,
                // as the real recognizer does; it must not open line 2.
                (1.5, token(".", 0.92)),
                (1.5, token("\u{2581}hola", 1.0)),
                (1.5, token("\u{2581}mundo", 1.08)),
            ])
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: "Others",
            resolver: FakeResolver("Speaker 2"), captureFormat: captureFormat, control: nil,
            sourceKey: "system", gapSeconds: 0.7, maxLineSeconds: 12,
            labelName: "test")
        for _ in 0..<12 { try sink.write(silence(0.25)) }
        await sink.finalizeAsync()

        let lines = try readLines(path)
        try #require(lines.count == 2)
        #expect(lines.map(\.text) == ["hello world", "hola mundo"])
        // Token ends are sums of 80 ms frames, so compare within a frame's worth
        // of floating-point slack rather than bit-exactly.
        #expect(abs(lines[0].start - 0.0) < 1e-9)
        #expect(abs(lines[0].end - 0.16) < 1e-9)
        #expect(abs(lines[1].start - 1.0) < 1e-9)
        #expect(abs(lines[1].end - 1.16) < 1e-9)
        #expect(lines.allSatisfy { $0.speaker == "Speaker 2" })
        // Monotonic, non-overlapping.
        #expect(lines[0].end <= lines[1].start)
    }

    /// The fixed source label is used when no resolver is attached.
    @Test func fallsBackToTheSourceLabel() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recognizer = ScriptedStreamingRecognizer(
            chunkSamples: 4000, script: [(0.25, token("\u{2581}mine", 0.0))])
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: "You",
            resolver: nil, captureFormat: captureFormat, control: nil, sourceKey: "mic",
            gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test")
        try sink.write(silence(0.25))
        await sink.finalizeAsync()
        let lines = try readLines(path)
        #expect(lines.count == 1)
        #expect(try #require(lines.first).speaker == "You")
    }

    /// The sink must measure the pause against audio the recognizer has decoded,
    /// not audio hark has fed it. Here 1 s has been fed but the engine's chunk is
    /// 1.5 s, so nothing is decoded yet: the line stays open. Measuring fed audio
    /// instead would see a 0.92 s pause and close the line mid-sentence, on
    /// silence nothing had looked at.
    @Test func doesNotCloseALineOnAudioTheEngineHasNotDecoded() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let control = CaptureControl()
        let recognizer = ScriptedStreamingRecognizer(
            chunkSamples: 24000, script: [(0.25, token("\u{2581}mid", 0.0))])
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: false, speaker: "Others",
            resolver: nil, captureFormat: captureFormat, control: control, sourceKey: "system",
            gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test")
        for _ in 0..<4 { try sink.write(silence(0.25)) }
        try await waitUntil { control.partialLine?.text == "mid" }
        #expect(control.partialLine?.text == "mid")
        #expect(try readLines(path).isEmpty)
        await sink.finalizeAsync()
        try? writer.close()
        // Teardown flushes it, so the words are never lost.
        #expect(try readLines(path).map(\.text) == ["mid"])
    }

    /// The open line is published while it grows and cleared once it closes.
    @Test func publishesThenClearsTheOpenLine() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let control = CaptureControl()
        let recognizer = ScriptedStreamingRecognizer(
            chunkSamples: 4000,
            script: [
                (0.5, token("\u{2581}so", 0.0)),
                (0.5, token("\u{2581}far", 0.08)),
            ])
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: "Others",
            resolver: nil, captureFormat: captureFormat, control: control, sourceKey: "system",
            gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test")

        // 0.5 s in: both tokens decoded, no pause yet, so the line is still open.
        try sink.write(silence(0.25))
        try sink.write(silence(0.25))
        try await waitUntil { control.partialLine?.text == "so far" }
        #expect(control.partialLine?.text == "so far")
        #expect(control.partialLine?.start == 0.0)
        #expect(control.partialLine?.speaker == "Others")

        // Past 0.86 s of decoded audio the trailing pause closes the line.
        try sink.write(silence(0.25))
        try sink.write(silence(0.25))
        try await waitUntil { control.partialLine == nil }
        #expect(control.partialLine == nil)

        await sink.finalizeAsync()
        #expect(try readLines(path).map(\.text) == ["so far"])
        #expect(control.partialLine == nil)
    }

    /// The shipping path. `CaptureEngine.run` finalizes its sinks with the
    /// synchronous `finalize()`, never `finalizeAsync()`, so the semaphore
    /// handshake and the tail flush at teardown are otherwise untested. This is
    /// the positive control that the handshake completes at all.
    ///
    /// `finalize()` runs on a real thread, as it does in production: blocking a
    /// cooperative worker instead starves the consumer `Task` it waits for (see
    /// `offCooperativePool`).
    @Test func finalizeFlushesTheTailFromABlockingCaller() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recognizer = ScriptedStreamingRecognizer(
            chunkSamples: 4000,
            script: [
                (0.25, token("\u{2581}tail", 0.0)),
                (0.5, token("\u{2581}flush", 0.08)),
            ])
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        // `finalizeTimeout: 0` waits for the decoder however long it takes. The
        // default inherits `$HARK_TEARDOWN_TIMEOUT` (5 s), and this test is about
        // the tail landing, not about the bound: under a full suite on a
        // single-wide cooperative pool the scripted decode can miss a 5 s wall
        // clock, and a timed-out finalize deliberately drops the tail, so the test
        // would fail for a reason it is not testing.
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: "You",
            resolver: nil, captureFormat: captureFormat, control: nil, sourceKey: "mic",
            gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test", finalizeTimeout: 0)
        let chunk = silence(0.25)
        try await offCooperativePool {
            try sink.write(chunk)
            try sink.write(chunk)
            // No pause has closed the line, so the only way these words reach the
            // transcript is the tail flush inside the finalize handshake.
            try sink.finalize()
        }
        let lines = try readLines(path)
        #expect(lines.map(\.text) == ["tail flush"])
        #expect(try #require(lines.first).speaker == "You")
    }

    /// A sink built and then abandoned (the second `makeRecognizer()` of a
    /// two-source capture throws, or `session.start` does) is never finalized, so
    /// its consumer `Task` must not be what keeps it alive. A strong capture there
    /// pins the recognizer's per-stream state and the shared model handles for the
    /// life of the process, which in the long-lived remote agent is per `POST /start`.
    @Test func releasesASinkThatIsNeverFinalized() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let abandoned = WeakSinkBox()
        func buildThenDrop() throws {
            let recognizer = ScriptedStreamingRecognizer(
                chunkSamples: 4000, script: [(0.25, token("\u{2581}gone", 0.0))])
            let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
            let sink = StreamingLiveTranscriber(
                recognizer: recognizer, writer: writer, ownsWriter: true, speaker: nil,
                resolver: nil, captureFormat: captureFormat, control: nil, sourceKey: "single",
                gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test")
            abandoned.sink = sink
            try sink.write(silence(0.25))
        }
        try buildThenDrop()
        try await waitUntil { abandoned.sink == nil }
        #expect(abandoned.sink == nil, "the consumer Task still retains a sink nobody finalized")
    }

    /// Stop is bounded. A decoder that never answers used to hold `finalize()`
    /// open for as long as it stayed behind, which in `CaptureEngine.run` is the
    /// one step before the recording is handed back.
    @Test func finalizeGivesUpOnADecoderThatNeverAnswers() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let released = WeakSinkBox()
        // The sink exists only inside here, so the weak check afterwards is a real
        // one rather than a read through a binding still in scope.
        func stopADecoderThatNeverAnswers() async throws -> Duration {
            let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
            let sink = StreamingLiveTranscriber(
                recognizer: StalledStreamingRecognizer(), writer: writer, ownsWriter: true,
                speaker: nil, resolver: nil, captureFormat: captureFormat, control: nil,
                sourceKey: "single", gapSeconds: 0.7, maxLineSeconds: 12, labelName: "test",
                finalizeTimeout: 1)
            released.sink = sink
            let chunk = silence(0.25)
            // A real thread, so the decoder genuinely gets to run and hang: the
            // only reason `finalize()` comes back is the bound.
            return try await offCooperativePool { () -> Duration in
                try sink.write(chunk)
                let started = ContinuousClock.now
                try sink.finalize()
                return ContinuousClock.now - started
            }
        }
        let waited = try await stopADecoderThatNeverAnswers()
        // The budget is 1 s. Five is loose enough for a loaded runner and still
        // fails long before the suite timeout, which is how this used to be caught.
        #expect(waited < .seconds(5))
        // Cleanup, and a check in its own right: the timed-out finalize cancels the
        // consumer Task, so the 3600 s sleep throws instead of parking a thread and
        // a live sink with its recognizer for the rest of the suite.
        try await waitUntil { released.sink == nil }
        #expect(released.sink == nil, "the abandoned sink outlived its timed-out finalize")
    }

    /// The point of the bound is that stop really is over when it returns.
    ///
    /// `CaptureEngine.run` hands the recording back as soon as `finalize()`
    /// returns and `RemoteControlAgent` reports the session finished right after,
    /// so a client reading the transcript on that signal must not find it growing
    /// afterwards. The decoder here comes back with a word only after the bound has
    /// expired, which is what a CoreML call minutes behind actually does.
    @Test func nothingReachesTheTranscriptAfterAFinalizeGivesUp() async throws {
        let path = tempTranscriptPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recognizer = ReleasableStreamingRecognizer()
        let control = CaptureControl()
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: "You",
            resolver: nil, captureFormat: captureFormat, control: control,
            sourceKey: "single", gapSeconds: 0.12, maxLineSeconds: 12, labelName: "test",
            finalizeTimeout: 0.5)

        // Feed first and wait for the decoder to actually be inside `process`, so
        // the bound below expires on a parked decode rather than racing the
        // scheduler for it. On a single-wide cooperative pool under the full suite
        // the consumer Task can otherwise take longer than the budget just to start.
        try sink.write(silence(0.25))
        try await waitUntil { recognizer.hasParked }
        #expect(recognizer.hasParked, "the decoder never got to run, so nothing was pending")

        let waited = try await offCooperativePool { () -> Duration in
            let started = ContinuousClock.now
            try sink.finalize()
            return ContinuousClock.now - started
        }
        #expect(waited < .seconds(5))
        #expect(try readLines(path).isEmpty, "a line landed before the decoder answered")

        // Now the decoder answers, after the recording was handed back. Its word
        // would close a line: 0.17 s of decoded silence past it is more than the
        // 0.12 s gap. It must not reach the transcript, the status partial or the
        // screen.
        recognizer.release()
        try await waitUntil { recognizer.hasReturned }
        #expect(recognizer.hasReturned, "the decoder never came back, so nothing was proved")
        try await waitUntil(timeout: .milliseconds(500)) { !((try? readLines(path))?.isEmpty ?? true) }
        #expect(
            try readLines(path).isEmpty,
            "a line landed after finalize() returned and the session was reported finished")
        #expect(control.partialLine == nil, "the open line was republished after stop")
    }

    /// Two streams publish independently: clearing one leaves the other, and the
    /// newest line is the one `GET /status` reports.
    @Test func newestSourceWinsAndClearingOneKeepsTheOther() {
        let control = CaptureControl()
        control.setPartial(PartialLine(text: "mic side", start: 1, speaker: "You"), for: "mic")
        #expect(control.partialLine?.text == "mic side")
        control.setPartial(
            PartialLine(text: "call side", start: 2, speaker: "Speaker 1"), for: "system")
        #expect(control.partialLine?.text == "call side")
        control.setPartial(nil, for: "system")
        #expect(control.partialLine?.text == "mic side")
        control.setPartial(nil, for: "mic")
        #expect(control.partialLine == nil)
    }

    /// A stop clears the open lines and refuses later ones, so a slow decode
    /// cannot resurrect text after the recording ended.
    @Test func stopClearsAndRefusesPartials() {
        let control = CaptureControl()
        control.setPartial(PartialLine(text: "half a line", start: 3, speaker: nil), for: "mic")
        #expect(control.partialLine != nil)
        control.stop()
        #expect(control.partialLine == nil)
        control.setPartial(PartialLine(text: "late", start: 4, speaker: nil), for: "mic")
        #expect(control.partialLine == nil)
    }

    // MARK: Status payload

    @Test func statusEncodesThePartialLine() throws {
        let snapshot = RemoteSessionManager.Snapshot(
            id: "s1", state: .recording, startedAt: Date(), audio: nil,
            transcript: "n.json", hasMic: true, muted: false, error: nil,
            partial: PartialLine(text: "so the plan is to", start: 809.8, speaker: "Speaker 2"))
        let data = try JSONEncoder().encode(
            StatusResponse(version: harkVersion, address: "127.0.0.1:8473", session: snapshot))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        let partial = try #require(session["partial"] as? [String: Any])
        #expect(partial["text"] as? String == "so the plan is to")
        #expect(partial["speaker"] as? String == "Speaker 2")
    }

    /// With streaming off there is no partial, and the key is absent rather than
    /// null, so the payload stays byte-identical to the pre-streaming agent.
    @Test func statusOmitsThePartialKeyWhenThereIsNone() throws {
        let snapshot = RemoteSessionManager.Snapshot(
            id: "s1", state: .recording, startedAt: Date(), audio: nil,
            transcript: "n.json", hasMic: true, muted: false, error: nil)
        let data = try JSONEncoder().encode(
            StatusResponse(version: harkVersion, address: "127.0.0.1:8473", session: snapshot))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("partial"))
    }

    /// The snapshot only carries a partial while recording: a paused or stopped
    /// session must not keep showing text that is no longer being produced.
    @Test func snapshotDropsThePartialOnceNotRecording() throws {
        let manager = RemoteSessionManager()
        let control = CaptureControl()
        _ = try manager.begin(
            id: "a", control: control, hasMic: true, muted: false,
            audio: nil, transcript: "n.json")
        control.setPartial(PartialLine(text: "still talking", start: 5, speaker: nil), for: "mic")
        #expect(manager.current()?.partial?.text == "still talking")

        // Paused: the control still holds the line, the snapshot must not.
        _ = try manager.pause()
        #expect(control.partialLine != nil)
        #expect(manager.current()?.partial == nil)

        // Stopped: the control is cleared too.
        _ = try manager.resume()
        _ = try manager.stop()
        #expect(control.partialLine == nil)
        #expect(manager.current()?.partial == nil)
    }
}

@Suite("Streaming transcription settings")
struct StreamingSettingsTests {
    private func resolve(
        _ args: [String], env: [String: String] = [:], config: Configuration = Configuration()
    ) throws -> ResolvedSettings {
        try ResolvedSettings.resolve(from: try Hark.parse(args), environment: env, config: config)
    }

    @Test func defaultsToOff() throws {
        #expect(try resolve([]).liveStreaming == false)
    }

    @Test func readsTheFlagEnvAndConfig() throws {
        #expect(try resolve(["--live-streaming"]).liveStreaming == true)
        #expect(try resolve([], env: ["HARK_LIVE_STREAMING": "true"]).liveStreaming == true)
        #expect(try resolve([], config: Configuration(liveStreaming: true)).liveStreaming == true)
        // The flag wins over both.
        #expect(
            try resolve(
                ["--no-live-streaming"], env: ["HARK_LIVE_STREAMING": "true"],
                config: Configuration(liveStreaming: true)
            ).liveStreaming == false)
    }

    /// The streaming recognizer is verbatim-only, so the pairing must fail however
    /// it is spelled: one check in `ResolvedSettings.validate` covers flag, env and
    /// config.
    @Test func refusesTranslate() throws {
        #expect(throws: HarkError.self) {
            try resolve(["--live-streaming", "--translate"]).validate()
        }
        #expect(throws: HarkError.self) {
            try resolve([], env: ["HARK_LIVE_STREAMING": "true", "HARK_TRANSLATE": "true"])
                .validate()
        }
        #expect(throws: Never.self) { try resolve(["--live-streaming"]).validate() }
    }

    /// Without a transcript output there is nothing to stream into, so the models
    /// must not be loaded (a 583 MB download on first use) for an audio-only run
    /// that has `live-streaming true` in its config.
    @Test func streamsOnlyWhenATranscriptIsWritten() throws {
        let on = try resolve(["--live-streaming"])
        #expect(Hark.streamingRequested(settings: on, hasTranscript: true))
        #expect(!Hark.streamingRequested(settings: on, hasTranscript: false))
        let off = try resolve([])
        #expect(!Hark.streamingRequested(settings: off, hasTranscript: true))
    }

    /// Streaming picks its own recognizer and segments on its own, so `--engine`
    /// and the VAD/gain/threshold settings silently stop applying. Someone with
    /// `engine: parakeet` in their config who adds `--live-streaming` transcribes
    /// with Nemotron instead, and has to be told. Only deliberate settings count:
    /// a default nobody chose is not worth a notice.
    @Test func namesOnlyTheIgnoredSettingsTheUserActuallySet() throws {
        func ignored(
            _ args: [String], env: [String: String] = [:],
            config: Configuration = Configuration()
        ) throws -> [String] {
            Hark.streamingIgnoredSettings(
                from: try Hark.parse(args), environment: env, config: config)
        }
        #expect(try ignored(["--live-streaming"]) == [])
        #expect(try ignored(["--live-streaming", "-e", "parakeet"]) == ["--engine"])
        #expect(try ignored(["--live-streaming"], env: ["HARK_VAD": "0"]) == ["--vad"])
        #expect(
            try ignored(["--live-streaming"], config: Configuration(engine: "parakeet"))
                == ["--engine"])
        #expect(try ignored(["--live-streaming", "--no-gain"]) == ["--gain"])
        // Not ignored: the same live run hands --silence-threshold to
        // makeAudioSink, where it decides every --split silence:<n> boundary.
        // Naming it would tell the user their split threshold does not apply
        // while it is the only thing setting it.
        #expect(try ignored(["--live-streaming", "--silence-threshold=-40"]) == [])
        #expect(
            try ignored(["--live-streaming"], env: ["HARK_SILENCE_THRESHOLD": "-40"]) == [])
        #expect(
            try ignored(["--live-streaming"], config: Configuration(silenceThreshold: -40))
                == [])
    }

    /// A file is transcribed in one pass, so the flag has nothing to stream.
    @Test func refusesFileInput() throws {
        var message = ""
        do {
            try Hark.parse(["--live-streaming", "-i", "in.wav"]).validate()
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("--live-streaming applies to live capture"))
        #expect(throws: Never.self) { try Hark.parse(["--live-streaming"]).validate() }
    }

    /// Only the Latin-script ship is downloaded, so a language outside it has to
    /// take the segmented path rather than silently pull the 665 MB full-vocab
    /// model.
    @Test func acceptsOnlyTheLatinScriptLanguages() throws {
        for hint in ["auto", "en", "en-us", "es", "es-419", "fr", "it", "pt", "de"] {
            #expect(throws: Never.self) {
                try NemotronStreamingModels.requireSupported(hint)
            }
        }
        for hint in ["zh", "ja", "ru", "ko"] {
            #expect(throws: HarkError.self) {
                try NemotronStreamingModels.requireSupported(hint)
            }
        }
    }

    @Test func normalizesTheLanguageHint() {
        #expect(NemotronStreamingModels.normalizedLanguage(nil) == "auto")
        #expect(NemotronStreamingModels.normalizedLanguage("") == "auto")
        #expect(NemotronStreamingModels.normalizedLanguage("ES-419") == "es-419")
    }

    /// The bundle path has to match FluidAudio's own cache layout
    /// (`<repo folder>/<vocab ship>/<chunk tier>`), or the "already cached" check
    /// never sees the model and every run prints a download notice.
    @Test func bundlePathMatchesTheCacheLayout() {
        #expect(NemotronStreamingModels.bundle == "nemotron-multilingual/latin/560ms")
        #expect(NemotronStreamingModels.chunkMs == 560)
    }

    @Test func modelCatalogOffersTheStreamingRecognizer() {
        let spec = ModelCatalog.parse("fluidaudio:streaming-asr")
        #expect(spec.engine == "fluidaudio")
        #expect(spec.modelId == "streaming-asr")
        #expect(
            ModelCatalog.available().contains {
                $0.engine == "fluidaudio" && $0.modelId == "streaming-asr"
            })
    }
}

/// Polls `condition` until it holds or the deadline passes. The sink consumes
/// audio on its own Task, so a mid-stream assertion has to wait for it; a
/// condition that never holds fails the following `#expect` instead of hanging.
private func waitUntil(
    timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
