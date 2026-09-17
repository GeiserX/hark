import ArgumentParser
import Foundation
import Testing

@testable import CLI

/// A scripted collision prompt: records what it was asked and answers with a
/// fixed choice, so the policy matrix is testable without a terminal.
final class FakeCollisionPrompt: CollisionPrompt, @unchecked Sendable {
    let isAvailable: Bool
    private let answer: CollisionChoice?
    private(set) var asked: [(existing: [String], preview: [String])] = []

    init(available: Bool = true, answer: CollisionChoice? = nil) {
        self.isAvailable = available
        self.answer = answer
    }

    func ask(existing: [String], uniquePreview: [String]) -> CollisionChoice? {
        asked.append((existing, uniquePreview))
        return answer
    }
}

/// Scratch directory for one test, removed afterwards.
private struct Scratch {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-guard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    @discardableResult
    func touch(_ name: String, contents: String = "old") -> String {
        let path = self.path(name)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func contents(_ name: String) -> String? {
        try? String(contentsOfFile: path(name), encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Output guard")
struct OutputGuardTests {
    private func outputs(audio: String? = nil, transcript: String? = nil) -> Hark.ResolvedOutputs {
        Hark.ResolvedOutputs(
            audio: audio.map { .file($0) }, transcript: transcript.map { .file($0) })
    }

    // MARK: No collision

    @Test func freePathsPassThrough() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let prompt = FakeCollisionPrompt(answer: .overwrite)
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.m4a"), transcript: scratch.path("rec.txt")),
            split: nil, policy: .ask, prompt: prompt)
        guard case .file(let audio)? = resolved.audio, case .file(let text)? = resolved.transcript
        else {
            Issue.record("expected both file destinations")
            return
        }
        #expect(audio == scratch.path("rec.m4a"))
        #expect(text == scratch.path("rec.txt"))
        #expect(prompt.asked.isEmpty)  // nothing existed, so nothing to ask
    }

    /// stdout destinations can't collide, so they're never checked (a file
    /// literally named "-" in the working directory is irrelevant).
    @Test func stdoutDestinationsAreExempt() throws {
        let prompt = FakeCollisionPrompt(available: false)
        let resolved = try OutputGuard.prepare(
            Hark.ResolvedOutputs(audio: .stdoutWav, transcript: .stdout),
            split: nil, policy: .error, prompt: prompt)
        guard case .stdoutWav? = resolved.audio, case .stdout? = resolved.transcript else {
            Issue.record("expected stdout destinations to pass through")
            return
        }
    }

    // MARK: Non-interactive policies

    @Test func errorPolicyRefusesAndKeepsTheFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a", contents: "keep me")
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.prepare(
                outputs(audio: scratch.path("rec.m4a")), split: nil, policy: .error,
                prompt: FakeCollisionPrompt(available: false))
        }
        #expect(error?.code == .cantCreate)
        #expect(error?.message.contains("--if-exists") == true)
        #expect(scratch.contents("rec.m4a") == "keep me")
    }

    @Test func overwritePolicyKeepsTheRequestedPaths() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a")
        scratch.touch("rec.txt")
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.m4a"), transcript: scratch.path("rec.txt")),
            split: nil, policy: .overwrite, prompt: FakeCollisionPrompt(available: false))
        guard case .file(let audio)? = resolved.audio, case .file(let text)? = resolved.transcript
        else {
            Issue.record("expected both file destinations")
            return
        }
        #expect(audio == scratch.path("rec.m4a"))
        #expect(text == scratch.path("rec.txt"))
    }

    /// The whole invocation shares one suffix, so a partially colliding
    /// audio/transcript pair still lands on matching names.
    @Test func uniqueRenamesTheWholeSetTogether() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a")  // only the audio exists
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.m4a"), transcript: scratch.path("rec.txt")),
            split: nil, policy: .unique, prompt: FakeCollisionPrompt(available: false))
        guard case .file(let audio)? = resolved.audio, case .file(let text)? = resolved.transcript
        else {
            Issue.record("expected both file destinations")
            return
        }
        #expect(audio == scratch.path("rec-1.m4a"))
        #expect(text == scratch.path("rec-1.txt"))
        #expect(scratch.exists("rec.m4a"))  // untouched
    }

    @Test func uniquePicksTheFirstSuffixFreeForEveryOutput() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a")
        scratch.touch("rec-1.m4a")
        scratch.touch("rec-2.txt")  // blocks -2 for the pair, even though -2.m4a is free
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.m4a"), transcript: scratch.path("rec.txt")),
            split: nil, policy: .unique, prompt: FakeCollisionPrompt(available: false))
        guard case .file(let audio)? = resolved.audio, case .file(let text)? = resolved.transcript
        else {
            Issue.record("expected both file destinations")
            return
        }
        #expect(audio == scratch.path("rec-3.m4a"))
        #expect(text == scratch.path("rec-3.txt"))
    }

    @Test func suffixGoesBeforeTheExtension() {
        #expect(OutputGuard.apply(suffix: 1, to: "rec.m4a") == "rec-1.m4a")
        #expect(OutputGuard.apply(suffix: 7, to: "/tmp/a.b/notes.txt") == "/tmp/a.b/notes-7.txt")
        #expect(OutputGuard.apply(suffix: 2, to: "recording") == "recording-2")
    }

    // MARK: ask

    @Test func askPromptsOnceForTheWholeSet() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a")
        scratch.touch("rec.txt")
        let prompt = FakeCollisionPrompt(answer: .unique)
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.m4a"), transcript: scratch.path("rec.txt")),
            split: nil, policy: .ask, prompt: prompt)
        #expect(prompt.asked.count == 1)
        #expect(prompt.asked.first?.existing.count == 2)
        #expect(prompt.asked.first?.preview == [scratch.path("rec-1.m4a"), scratch.path("rec-1.txt")])
        guard case .file(let audio)? = resolved.audio else {
            Issue.record("expected an audio file")
            return
        }
        #expect(audio == scratch.path("rec-1.m4a"))
    }

    @Test func askWithoutATerminalBecomesAnError() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.txt")
        let prompt = FakeCollisionPrompt(available: false, answer: .overwrite)
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.prepare(
                outputs(transcript: scratch.path("rec.txt")), split: nil, policy: .ask,
                prompt: prompt)
        }
        #expect(error?.code == .cantCreate)
        #expect(error?.message.contains("no terminal") == true)
        #expect(prompt.asked.isEmpty)
    }

    @Test func cancelRefusesAndLeavesEverythingInPlace() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.txt", contents: "yesterday")
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.prepare(
                outputs(transcript: scratch.path("rec.txt")), split: nil, policy: .ask,
                prompt: FakeCollisionPrompt(answer: .cancel))
        }
        #expect(error?.code == .cantCreate)
        #expect(scratch.contents("rec.txt") == "yesterday")
    }

    /// An unreadable answer must not be taken as consent to destroy anything.
    @Test func unreadableAnswerCancels() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.txt")
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.prepare(
                outputs(transcript: scratch.path("rec.txt")), split: nil, policy: .ask,
                prompt: FakeCollisionPrompt(answer: nil))
        }
        #expect(error?.code == .cantCreate)
        #expect(scratch.exists("rec.txt"))
    }

    // MARK: --split chunk sets

    @Test func chunkSetSeesChunksNotTheBaseName() {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec_001.wav")
        scratch.touch("rec_010.wav")
        scratch.touch("rec.wav")  // the base name itself is never written by --split
        scratch.touch("rec_001.mp3")  // different format
        scratch.touch("other_001.wav")  // different stem
        let chunks = OutputGuard.existingChunks(base: scratch.path("rec.wav"))
        #expect(chunks == [scratch.path("rec_001.wav"), scratch.path("rec_010.wav")])
    }

    @Test func overwritePurgesStaleChunks() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        for index in 1...3 { scratch.touch(String(format: "rec_%03d.wav", index)) }
        _ = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.wav")), split: .duration(2), policy: .overwrite,
            prompt: FakeCollisionPrompt(available: false))
        // A shorter run must not leave the previous session's chunks behind.
        #expect(!scratch.exists("rec_001.wav"))
        #expect(!scratch.exists("rec_002.wav"))
        #expect(!scratch.exists("rec_003.wav"))
    }

    @Test func uniqueMovesTheChunkSetToAFreeBaseName() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec_001.wav")
        let resolved = try OutputGuard.prepare(
            outputs(audio: scratch.path("rec.wav")), split: .duration(2), policy: .unique,
            prompt: FakeCollisionPrompt(available: false))
        guard case .file(let base)? = resolved.audio else {
            Issue.record("expected an audio file")
            return
        }
        #expect(base == scratch.path("rec-1.wav"))  // chunks become rec-1_001.wav, …
        #expect(scratch.exists("rec_001.wav"))  // previous session untouched
    }

    // MARK: Directories and self-overwrite

    @Test func aDirectoryOutputIsRejected() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.prepare(
                outputs(audio: scratch.url.path), split: nil, policy: .overwrite,
                prompt: FakeCollisionPrompt(available: false))
        }
        #expect(error?.code == .cantCreate)
        #expect(error?.message.contains("is a directory") == true)
    }

    @Test func outputCannotBeTheInputFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let source = scratch.touch("clip.wav")
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.checkDistinct(input: source, outputs: outputs(audio: source))
        }
        #expect(error?.code == .usage)
        // The same file reached by a different spelling is still the same file.
        let error2 = #expect(throws: HarkError.self) {
            try OutputGuard.checkDistinct(
                input: scratch.path("./clip.wav"), outputs: outputs(audio: source))
        }
        #expect(error2?.code == .usage)
    }

    @Test func audioAndTranscriptCannotShareAPath() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let path = scratch.path("both.txt")
        let error = #expect(throws: HarkError.self) {
            try OutputGuard.checkDistinct(
                input: nil, outputs: outputs(audio: path, transcript: path))
        }
        #expect(error?.code == .usage)
    }

    @Test func distinctPathsAreAccepted() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let source = scratch.touch("clip.wav")
        try OutputGuard.checkDistinct(
            input: source,
            outputs: outputs(audio: scratch.path("out.m4a"), transcript: scratch.path("out.txt")))
        // stdin/stdout are never files.
        try OutputGuard.checkDistinct(input: "-", outputs: outputs(audio: scratch.path("out.m4a")))
    }

    // MARK: Through the command

    @Test func commandAppliesTheResolvedPolicy() throws {
        let scratch = Scratch()
        defer { scratch.cleanup() }
        scratch.touch("rec.m4a")
        let hark = try Hark.parse([
            "-a", scratch.path("rec.m4a"), "-t", scratch.path("rec.srt"),
            "--if-exists", "unique",
        ])
        let settings = try ResolvedSettings.resolve(
            from: hark, environment: [:], config: Configuration())
        #expect(settings.ifExists == .unique)
        let resolved = try hark.guardedOutputs(
            try hark.resolveOutputs(), settings: settings,
            prompt: FakeCollisionPrompt(available: false))
        guard case .file(let audio)? = resolved.audio, case .file(let text)? = resolved.transcript
        else {
            Issue.record("expected both file destinations")
            return
        }
        #expect(audio == scratch.path("rec-1.m4a"))
        #expect(text == scratch.path("rec-1.srt"))
    }

    @Test func policyFollowsEnvAndConfigPrecedence() throws {
        let bare = try Hark.parse(["-a", "rec.m4a"])
        #expect(
            try ResolvedSettings.resolve(from: bare, environment: [:], config: Configuration())
                .ifExists == .ask)
        #expect(
            try ResolvedSettings.resolve(
                from: bare, environment: [:], config: Configuration(ifExists: "overwrite")
            ).ifExists == .overwrite)
        #expect(
            try ResolvedSettings.resolve(
                from: bare, environment: ["HARK_IF_EXISTS": "unique"],
                config: Configuration(ifExists: "overwrite")
            ).ifExists == .unique)
        let flagged = try Hark.parse(["-a", "rec.m4a", "--if-exists", "error"])
        #expect(
            try ResolvedSettings.resolve(
                from: flagged, environment: ["HARK_IF_EXISTS": "unique"],
                config: Configuration(ifExists: "overwrite")
            ).ifExists == .error)
    }

    @Test func invalidPolicyValuesAreRejected() {
        #expect(throws: (any Error).self) {
            try Hark.parse(["-a", "rec.m4a", "--if-exists", "clobber"])
        }
        #expect(throws: HarkError.self) {
            try ResolvedSettings.resolve(
                from: try Hark.parse(["-a", "rec.m4a"]),
                environment: ["HARK_IF_EXISTS": "maybe"], config: Configuration())
        }
    }

    @Test func messageListsFilesReadably() {
        #expect(OutputGuard.describe(["a.wav"]) == "'a.wav'")
        #expect(OutputGuard.describe(["a.wav", "b.txt"]) == "'a.wav' and 'b.txt'")
        #expect(
            OutputGuard.describe(["a.wav", "b.wav", "c.wav"]) == "'a.wav', 'b.wav' and 'c.wav'")
        #expect(OutputGuard.describe((1...9).map { "c\($0).wav" }).contains("(9 files)"))
    }
}
