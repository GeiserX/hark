import Encoders
import FluidAudio
import Foundation
import Testing

@testable import CLI

/// End-to-end validation of `--live-streaming` against the real Nemotron
/// multilingual streaming model, on `say`-synthesized English and Spanish with
/// exact ground truth. Proves three things the model-free suite cannot: the model
/// loads from the Latin-script ship, the recognized text is right in both
/// languages, and the line timings land inside the windows the audio actually
/// occupies.
///
/// Gated: it downloads ~583 MB on first run and loads CoreML, so it is off in the
/// normal suite. Enable with `HARK_TEST_STREAMING=1` on Apple Silicon. SKIPs
/// cleanly when a requested `say` voice is unavailable.
///
/// Audio never reaches the speakers: every clip is synthesized with `say -o` to a
/// file and read back as samples.
@Suite("Streaming transcription (say, integration)")
struct SayStreamingTests {
    private struct Turn {
        let voice: String
        let text: String
    }

    private let captureFormat = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["HARK_TEST_STREAMING"] == "1" && Platform.isAppleSilicon
    }

    /// Synthesizes one line to 16 kHz mono Float via `say -o` (a file, never a
    /// device). Returns [] when the voice is unavailable, so the test SKIPs.
    private func synth(voice: String, text: String) -> [Float] {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", aiff.path, text]
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return (try? AudioConverter().resampleAudioFile(aiff)) ?? []
    }

    /// Splices turns into one stream with a lead-in and a pause between them,
    /// returning each turn's ground-truth window in seconds.
    private func conversation(
        _ turns: [Turn], leadIn: Double = 1.0, gap: Double = 1.5
    ) -> (samples: [Float], windows: [(start: Double, end: Double)])? {
        let rate = 16000.0
        var samples = [Float](repeating: 0, count: Int(leadIn * rate))
        var windows: [(Double, Double)] = []
        let silence = [Float](repeating: 0, count: Int(gap * rate))
        for turn in turns {
            let speech = synth(voice: turn.voice, text: turn.text)
            guard !speech.isEmpty else { return nil }
            let start = Double(samples.count) / rate
            samples.append(contentsOf: speech)
            windows.append((start, Double(samples.count) / rate))
            samples.append(contentsOf: silence)
        }
        return (samples, windows)
    }

    /// Feeds samples through a real `StreamingLiveTranscriber` in 0.25 s slices of
    /// 16 kHz mono 16-bit PCM (the identity-resampler path) and returns the
    /// transcript lines plus the mean wall time per recognizer chunk.
    private func transcribe(
        _ samples: [Float], recognizer: StreamingRecognizer, path: String
    ) async throws -> (lines: [(start: Double, end: Double, text: String)], msPerChunk: Double) {
        let writer = try LiveTranscriptWriter(destination: .file(path), format: .json)
        let sink = StreamingLiveTranscriber(
            recognizer: recognizer, writer: writer, ownsWriter: true, speaker: nil,
            resolver: nil, captureFormat: captureFormat, control: nil, sourceKey: "single",
            gapSeconds: 0.7, maxLineSeconds: 12, labelName: "say test")
        let sliceSamples = 4000
        let started = ContinuousClock.now
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + sliceSamples)
            try sink.write(VadSegmenter.packInt16(samples[offset..<end]))
            offset = end
        }
        await sink.finalizeAsync()
        let elapsed = ContinuousClock.now - started
        let seconds = Double(samples.count) / 16000
        let chunks = max(1.0, seconds / (Double(NemotronStreamingModels.chunkMs) / 1000))
        let msPerChunk =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return (try readTranscript(path), msPerChunk / chunks)
    }

    private func readTranscript(_ path: String) throws
        -> [(start: Double, end: Double, text: String)]
    {
        struct Line: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return try raw.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let decoded = try JSONDecoder().decode(Line.self, from: Data(trimmed.utf8))
            return (decoded.start, decoded.end, decoded.text)
        }
    }

    /// English then Spanish through one recognizer with the `auto` prompt: both
    /// transcribe, the lines stay inside their ground-truth windows, and the
    /// decoder keeps up with real time.
    @Test func transcribesEnglishAndSpanishFasterThanRealTime() async throws {
        guard enabled else { return }
        guard
            let call = conversation([
                Turn(
                    voice: "Daniel",
                    text: "The quarterly numbers are ready for review on Thursday."),
                Turn(voice: "Paulina", text: "Vamos a revisar las cifras del trimestre el jueves."),
            ])
        else { return }  // a voice is missing on this machine

        let models = try NemotronStreamingModels.load(language: nil)
        // The Latin-script ship must be what landed; "auto" on the download
        // selector would have fetched the 665 MB full-vocab model instead.
        #expect(FluidAudioCache.isCached(NemotronStreamingModels.bundle))
        #expect(
            FileManager.default.fileExists(
                atPath: FluidAudioCache.modelsDirectory
                    .appendingPathComponent(NemotronStreamingModels.bundle)
                    .appendingPathComponent("metadata.json").path))

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-say-stream-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await transcribe(
            call.samples, recognizer: try models.makeRecognizer(), path: path)

        print("streaming: \(String(format: "%.0f", result.msPerChunk)) ms per \(NemotronStreamingModels.chunkMs) ms chunk")
        for line in result.lines {
            print("  [\(String(format: "%.2f", line.start))–\(String(format: "%.2f", line.end))] \(line.text)")
        }

        try #require(result.lines.count >= 2)
        let joined = result.lines.map(\.text).joined(separator: " ").lowercased()
        #expect(result.lines.first!.text.lowercased().contains("thursday"))
        #expect(result.lines.last!.text.lowercased().contains("jueves"))
        #expect(joined.contains("quarterly"))

        // Every line sits inside one ground-truth window, widened by 0.4 s for the
        // recognizer's 80 ms frame quantisation and its chunk boundary.
        for line in result.lines {
            let fits = call.windows.contains { window in
                line.start >= window.start - 0.4 && line.end <= window.end + 0.4
            }
            #expect(fits, "line [\(line.start)–\(line.end)] is outside every spoken window")
        }

        // Real time is the whole point: a chunk must decode in under its duration.
        #expect(result.msPerChunk < Double(NemotronStreamingModels.chunkMs))
    }

    /// The two-source plan runs one recognizer per stream over a single shared
    /// model set. Both must stay under real time concurrently, or a `--mix`
    /// capture falls behind.
    @Test func twoConcurrentRecognizersStayUnderRealTime() async throws {
        guard enabled else { return }
        guard
            let call = conversation([
                Turn(voice: "Daniel", text: "The quarterly numbers are ready for review."),
                Turn(voice: "Paulina", text: "Vamos a revisar las cifras del trimestre."),
            ])
        else { return }

        let models = try NemotronStreamingModels.load(language: nil)
        let first = try models.makeRecognizer()
        let second = try models.makeRecognizer()
        let pathA = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-say-stream-a-\(UUID().uuidString).json").path
        let pathB = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-say-stream-b-\(UUID().uuidString).json").path
        defer {
            try? FileManager.default.removeItem(atPath: pathA)
            try? FileManager.default.removeItem(atPath: pathB)
        }

        async let runA = transcribe(call.samples, recognizer: first, path: pathA)
        async let runB = transcribe(call.samples, recognizer: second, path: pathB)
        let (resultA, resultB) = try await (runA, runB)

        print(
            "two streams: \(String(format: "%.0f", resultA.msPerChunk)) ms and "
                + "\(String(format: "%.0f", resultB.msPerChunk)) ms per \(NemotronStreamingModels.chunkMs) ms chunk")
        #expect(!resultA.lines.isEmpty)
        #expect(!resultB.lines.isEmpty)
        #expect(resultA.msPerChunk < Double(NemotronStreamingModels.chunkMs))
        #expect(resultB.msPerChunk < Double(NemotronStreamingModels.chunkMs))
    }
}
