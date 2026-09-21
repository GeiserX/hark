import FluidAudio
import Foundation

/// One loaded copy of the Nemotron multilingual streaming CoreML models, shared
/// by every stream of a capture. The model handles are ~1.5 GB; per-stream state
/// is ~50 MB, so a two-source capture loads once and pays twice for state only.
///
/// This is the only file in hark that names FluidAudio's streaming types. The
/// rest of the live path talks to `StreamingRecognizer`.
final class NemotronStreamingModels: @unchecked Sendable {
    /// Chunk tier fed to the encoder: the model decodes this much audio at a
    /// time, so it is the floor under how late the text can be. The two Latin
    /// ships differ in nothing else, same `att_context_size`, same vocabulary,
    /// so the shorter tier costs only what a smaller window costs the model.
    /// Measured on 20 real recordings against the accurate pass hark runs after
    /// a call: English is identical at both tiers, 5.4% either way, and Spanish
    /// goes from 12.5% to 13.3%. Paying 0.8 pp of Spanish for text that lands
    /// four times sooner is worth it. 2240 ms is what FluidAudio recommends for
    /// throughput, which is not what a live transcript needs.
    static let chunkMs = 560

    /// Cache directory under `FluidAudioCache.modelsDirectory`. The repo folder
    /// name is `nemotron-multilingual` (FluidAudio's `Repo.folderName`), then
    /// `<vocab ship>/<chunk tier>`.
    static let bundle = "nemotron-multilingual/latin/\(chunkMs)ms"

    /// Languages the Latin-script ship covers. A `--language` outside this set
    /// would silently fall back to the 665 MB full-vocab ship, so it is refused
    /// and the segmented path handles it instead.
    static let supportedLanguages = ["en", "es", "fr", "it", "pt", "de"]

    private let shared: SharedNemotronMultilingualModels
    private let languageHint: String

    private init(shared: SharedNemotronMultilingualModels, languageHint: String) {
        self.shared = shared
        self.languageHint = languageHint
    }

    /// Loads (and on first use downloads) the shared model set. Throws
    /// `HarkError` when streaming cannot run, so callers fall back to the
    /// segmented path instead of failing the recording.
    static func load(language: String?) throws -> NemotronStreamingModels {
        try Platform.requireAppleSilicon(engine: "live streaming transcription")
        let hint = normalizedLanguage(language)
        try requireSupported(hint)
        if FluidAudioCache.isCached(bundle) {
            Log.verbose("loading streaming transcription model (\(bundle))")
        } else {
            Log.notice("downloading the streaming transcription model (612 MB, first use)…")
        }
        // "auto" is a prompt in the Latin metadata, but the *download* selector
        // routes "auto" to the full-vocab `multilingual/` ship. Ask for "en" so
        // the smaller Latin ship lands, then set the prompt to "auto" per stream
        // so English and Spanish share one call.
        let downloadCode = hint == "auto" ? "en" : hint
        let shared = try RunLoopBridge.runBlocking(timeout: 1800) {
            try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: downloadCode, chunkMs: chunkMs)
        }
        return NemotronStreamingModels(shared: shared, languageHint: hint)
    }

    /// Pre-downloads the CoreML bundle (no inference run), for
    /// `hark models download fluidaudio:streaming-asr`.
    static func download() throws {
        guard Platform.isAppleSilicon else {
            throw HarkError.unavailable(
                "live streaming transcription requires Apple Silicon (CoreML/ANE).")
        }
        if FluidAudioCache.isCached(bundle) {
            Log.notice("streaming transcription model already present")
            return
        }
        Log.notice("downloading streaming transcription model …")
        _ = try RunLoopBridge.runBlocking(timeout: 3600) {
            try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "en", chunkMs: chunkMs)
        }
    }

    /// A fresh per-stream recognizer over the shared models. Reset once here;
    /// never again, because `reset()` zeroes the engine's clock.
    func makeRecognizer() throws -> StreamingRecognizer {
        let shared = self.shared
        let hint = languageHint
        let recognizer: NemotronStreamingRecognizer = try RunLoopBridge.runBlocking(timeout: 600) {
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadFromShared(shared)
            await manager.setLanguage(hint)
            await manager.reset()
            return NemotronStreamingRecognizer(
                manager: manager, chunkSamples: await manager.config.chunkSamples)
        }
        return recognizer
    }

    /// `--language` (or config/env) lowercased, with unset/empty meaning `auto`.
    /// Pure, for testing.
    static func normalizedLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "auto" }
        return language.lowercased()
    }

    /// Throws when a language hint is outside the Latin-script ship. Pure, for
    /// testing.
    static func requireSupported(_ hint: String) throws {
        guard hint != "auto" else { return }
        guard !supportedLanguages.contains(where: { hint.hasPrefix($0) }) else { return }
        throw HarkError.unavailable(
            "live streaming covers \(supportedLanguages.joined(separator: ", ")); "
                + "--language \(hint) uses the segmented path")
    }
}

/// `StreamingRecognizer` over one `StreamingNemotronMultilingualAsrManager`.
///
/// The manager decodes whole chunks from sample zero and accumulates token
/// timings for the entire session, so the token list only ever grows and its
/// timestamps are absolute seconds from the first sample fed. Neither `reset()`
/// nor `finish()` is called per line: `reset()` zeroes the clock and drops the
/// encoder cache, `finish()` zero-pads a partial chunk and advances the frame
/// base by a whole chunk, so either one mid-call would corrupt every later
/// timestamp and every diarizer label.
final class NemotronStreamingRecognizer: StreamingRecognizer, @unchecked Sendable {
    private let manager: StreamingNemotronMultilingualAsrManager
    let chunkSamples: Int

    private let lock = NSLock()
    private var pushedSamples = 0
    private var chunksDecoded = 0
    private var tokens: [RecognizedToken] = []

    init(manager: StreamingNemotronMultilingualAsrManager, chunkSamples: Int) {
        self.manager = manager
        self.chunkSamples = max(1, chunkSamples)
    }

    func process(_ samples: [Float]) async throws -> [RecognizedToken] {
        _ = try await manager.process(samples: samples)
        let decodedMore = lock.withLock { () -> Bool in
            pushedSamples += samples.count
            let chunks = pushedSamples / chunkSamples
            defer { chunksDecoded = chunks }
            return chunks > chunksDecoded
        }
        // Re-reading the timings costs an actor hop and an array copy; the list
        // can only have changed when a new chunk went through the decoder.
        if decodedMore {
            let mapped = Self.map(await manager.getTokenTimings())
            lock.withLock { tokens = mapped }
        }
        return lock.withLock { tokens }
    }

    func finish() async throws -> [RecognizedToken] {
        let mapped = Self.map(try await manager.finishWithTokenTimings().timings)
        lock.withLock { tokens = mapped }
        return mapped
    }

    private static func map(_ timings: [TokenTiming]) -> [RecognizedToken] {
        timings.map {
            RecognizedToken(piece: $0.token, start: $0.startTime, end: $0.endTime)
        }
    }
}
