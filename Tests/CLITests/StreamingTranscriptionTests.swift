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
    /// must not be loaded (a 612 MB download on first use) for an audio-only run
    /// that has `live-streaming true` in its config.
    @Test func streamsOnlyWhenATranscriptIsWritten() throws {
        let on = try resolve(["--live-streaming"])
        #expect(Hark.streamingRequested(settings: on, hasTranscript: true))
        #expect(!Hark.streamingRequested(settings: on, hasTranscript: false))
        let off = try resolve([])
        #expect(!Hark.streamingRequested(settings: off, hasTranscript: true))
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
