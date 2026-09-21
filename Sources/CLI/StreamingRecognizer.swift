import Foundation

/// One streamed token in capture time (seconds from the first sample fed to the
/// recognizer). `piece` is the raw SentencePiece piece, U+2581 word marker
/// included, so word boundaries survive the trip out of the engine.
struct RecognizedToken: Sendable, Equatable {
    let piece: String
    let start: Double
    let end: Double
}

/// Cache-aware streaming recognizer over 16 kHz mono Float samples. Tokens are
/// never retracted: each `process` returns the whole token list emitted so far,
/// oldest first, so a caller can cut lines out of it with an integer watermark
/// instead of resetting the engine (a reset would zero its clock).
protocol StreamingRecognizer: Sendable {
    /// The engine's chunk size in 16 kHz samples. Audio shorter than one chunk
    /// stays buffered inside the recognizer until the chunk completes.
    var chunkSamples: Int { get }
    /// Feeds 16 kHz mono samples and returns every token decoded so far.
    func process(_ samples: [Float]) async throws -> [RecognizedToken]
    /// Flushes the buffered tail and returns the final full token list.
    func finish() async throws -> [RecognizedToken]
}

/// SentencePiece detokenizer: U+2581 starts a word, runs of spaces collapse to
/// one, and the result is trimmed. Mirrors
/// `NemotronMultilingualTokenizer.decode(ids:)` so a line cut inside hark reads
/// the same as the engine's own decoded text.
enum SentencePieceText {
    static let wordBoundary = "\u{2581}"

    static func join(_ tokens: ArraySlice<RecognizedToken>) -> String {
        var raw = ""
        for token in tokens {
            raw += token.piece.replacingOccurrences(of: wordBoundary, with: " ")
        }
        return raw
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func join(_ tokens: [RecognizedToken]) -> String { join(tokens[...]) }

    /// True when a piece carries no letters or digits, only punctuation (or just
    /// the bare word-boundary marker).
    static func isPunctuationOnly(_ piece: String) -> Bool {
        let body = piece.replacingOccurrences(of: wordBoundary, with: "")
        return !body.contains { $0.isLetter || $0.isNumber }
    }

    /// Drops punctuation-only tokens from the front of a line.
    ///
    /// The recognizer often emits a sentence's final period in the chunk *after*
    /// the pause that closed the line, so it arrives when the previous line is
    /// already written and append-only. Left alone it opens the next line, which
    /// then reads ". Vamos a revisar…". The period is already implied by the line
    /// break before it, so it is dropped and the line starts on its first word,
    /// keeping that word's timestamp exact.
    static func trimmingLeadingPunctuation(
        _ tokens: ArraySlice<RecognizedToken>
    ) -> ArraySlice<RecognizedToken> {
        var start = tokens.startIndex
        while start < tokens.endIndex, isPunctuationOnly(tokens[start].piece) {
            start += 1
        }
        return tokens[start..<tokens.endIndex]
    }
}

/// Where an append-only token stream breaks into transcript lines. Pure: no
/// audio, no models, no clock of its own — the caller supplies how much audio the
/// recognizer has actually decoded.
///
/// `finalized` is the watermark: every token before it is already written to the
/// transcript, everything from it onward is the open line.
struct StreamingLineCutter {
    /// Silence between two tokens that closes a line (`--segment-pause`).
    let gapSeconds: Double
    /// Longest a single line may run before it is cut anyway (`--segment-window`).
    let maxLineSeconds: Double

    private(set) var finalized = 0

    init(gapSeconds: Double, maxLineSeconds: Double) {
        self.gapSeconds = gapSeconds
        self.maxLineSeconds = maxLineSeconds
    }

    /// Returns the ranges of `tokens` that just closed, in order, advancing the
    /// watermark past them.
    ///
    /// `processedSeconds` is audio the recognizer has **decoded**, not audio the
    /// caller has fed: a chunk-based engine holds a partial chunk back, and
    /// treating fed audio as decoded closes a line on silence that was never
    /// looked at, so the tokens for that stretch land in the next line with
    /// timestamps behind the line already written. Pass `.infinity` at teardown
    /// to flush everything.
    mutating func cut(tokens: [RecognizedToken], processedSeconds: Double) -> [Range<Int>] {
        var closed: [Range<Int>] = []
        while finalized < tokens.count {
            // 1. A gap inside the pending tokens: cut at the gap.
            var gapIndex: Int? = nil
            var index = finalized + 1
            while index < tokens.count {
                if tokens[index].start - tokens[index - 1].end >= gapSeconds {
                    gapIndex = index
                    break
                }
                index += 1
            }
            if let gapIndex {
                closed.append(finalized..<gapIndex)
                finalized = gapIndex
                continue
            }
            // 2. Trailing silence: the decoded audio runs past the last token by
            //    a full pause, so the speaker has stopped.
            if processedSeconds - tokens[tokens.count - 1].end >= gapSeconds {
                closed.append(finalized..<tokens.count)
                finalized = tokens.count
                continue
            }
            // 3. Window cap: a monologue with no pause still has to emit.
            if processedSeconds - tokens[finalized].start >= maxLineSeconds {
                closed.append(finalized..<tokens.count)
                finalized = tokens.count
                continue
            }
            break
        }
        return closed
    }
}

/// The still-open line of a streaming transcription, published on `GET /status`
/// so a viewer can show text before it is final. The one deliberate exception to
/// the remote-control agent serving no transcript content: it exists only while a
/// recording is live, is never written to a file, and is replaced (not appended)
/// on every poll.
struct PartialLine: Sendable, Encodable, Equatable {
    let text: String
    /// Seconds into the capture where the open line starts.
    let start: Double
    let speaker: String?
}
