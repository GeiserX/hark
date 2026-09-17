import ArgumentParser
import Foundation

/// What to do when a file this invocation would write already exists
/// (`--if-exists` / `$HARK_IF_EXISTS` / `hark config`). The same rules apply to
/// audio and transcript outputs — there is no per-format special case.
enum ExistingFilePolicy: String, CaseIterable, ExpressibleByArgument {
    /// Ask on the terminal; falls back to `error` when there is no TTY.
    case ask
    /// Refuse to write and exit (`EX_CANTCREAT`).
    case error
    /// Truncate/replace the existing files.
    case overwrite
    /// Write to the next free numbered name (`rec.m4a` -> `rec-1.m4a`).
    case unique

    static var allowedNames: [String] { allCases.map(\.rawValue) }
}

/// The answer to a collision prompt. One decision covers every output of the
/// invocation, so an audio/transcript pair can never drift apart.
enum CollisionChoice: String {
    case overwrite
    case unique
    case cancel
}

/// Asks the user what to do about existing outputs. Injected so tests can drive
/// the decision without a terminal.
protocol CollisionPrompt {
    /// False when there is no interactive terminal (cron, pipes, the agent), in
    /// which case `ask` degrades to `error`.
    var isAvailable: Bool { get }
    /// Prompts for a decision; nil if the answer could not be read.
    func ask(existing: [String], uniquePreview: [String]) -> CollisionChoice?
}

/// Terminal prompt: writes the question to stderr (never stdout, which may carry
/// audio or the transcript) and reads a single word from stdin.
struct TerminalCollisionPrompt: CollisionPrompt {
    var isAvailable: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0 }

    func ask(existing: [String], uniquePreview: [String]) -> CollisionChoice? {
        let stderr = FileHandle.standardError
        func emit(_ text: String) {
            try? stderr.write(contentsOf: Data(text.utf8))
        }
        emit("hark: \(OutputGuard.describe(existing)) already exist\(existing.count == 1 ? "s" : "").\n")
        emit("      [o]verwrite  [u]nique -> \(OutputGuard.describe(uniquePreview))  [c]ancel\n")
        for _ in 0..<3 {
            emit("hark: what now? [o/u/c] ")
            guard let line = readLine(strippingNewline: true) else {
                emit("\n")
                return .cancel  // EOF: don't touch anything
            }
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "o", "overwrite": return .overwrite
            case "u", "unique": return .unique
            case "c", "cancel", "": return .cancel
            default: emit("hark: answer o, u, or c.\n")
            }
        }
        return .cancel
    }
}

/// Pre-flight protection for the files an invocation would create (PRD §6.1).
///
/// Every output of one run — the audio file (or its `--split` chunk set) and the
/// transcript file — is treated as a single **artifact set**: one decision
/// applies to all of them, and `unique` picks one suffix that is free for every
/// target so paired outputs stay aligned (`rec-1.m4a` + `rec-1.txt`).
///
/// Checks run before capture starts (before TCC prompts and model loading), so
/// nothing is destroyed and no long recording is lost to a late failure.
enum OutputGuard {
    /// The largest `-N` suffix tried before giving up.
    static let maxSuffix = 999

    /// A file this run would create. `--split` writes a numbered chunk set
    /// (`rec_001.wav`, `rec_002.wav`, …) rather than `path` itself.
    struct Target: Equatable {
        let path: String
        let isChunkSet: Bool

        init(path: String, isChunkSet: Bool = false) {
            self.path = path
            self.isChunkSet = isChunkSet
        }
    }

    // MARK: Entry point

    /// Resolves the outputs for one invocation, applying `policy` to any that
    /// already exist. Returns the (possibly renumbered) destinations to use.
    static func prepare(
        _ outputs: Hark.ResolvedOutputs, split: SplitSpec?, policy: ExistingFilePolicy,
        prompt: CollisionPrompt = TerminalCollisionPrompt(), fileManager: FileManager = .default
    ) throws -> Hark.ResolvedOutputs {
        // Only real files can collide; stdout and --no-output are exempt.
        var targets: [Target] = []
        if case .file(let path)? = outputs.audio {
            targets.append(Target(path: path, isChunkSet: split != nil))
        }
        if case .file(let path)? = outputs.transcript {
            targets.append(Target(path: path))
        }
        guard !targets.isEmpty else { return outputs }

        try rejectDirectories(targets, fileManager: fileManager)
        let existing = existingFiles(for: targets, fileManager: fileManager)
        guard !existing.isEmpty else { return outputs }

        switch try decide(
            targets: targets, existing: existing, policy: policy, prompt: prompt,
            fileManager: fileManager)
        {
        case .overwrite:
            // Purged chunks are already reported; only mention the rest.
            let purged = Set(try purge(targets, fileManager: fileManager))
            let truncated = existing.filter { !purged.contains($0) }
            if !truncated.isEmpty { Log.notice("overwriting \(describe(truncated))") }
            return outputs
        case .unique:
            guard let suffix = jointSuffix(for: targets, fileManager: fileManager) else {
                throw HarkError.cantCreate(
                    "no free name for \(describe(targets.map(\.path))) after \(maxSuffix) tries.")
            }
            let renamed = rename(outputs, suffix: suffix)
            Log.notice(
                "writing to \(describe(displayPaths(targets, suffix: suffix))) — "
                    + "\(describe(existing)) already exist\(existing.count == 1 ? "s" : "")")
            return renamed.outputs
        case .cancel:
            throw HarkError.cantCreate("cancelled; \(describe(existing)) left untouched.")
        }
    }

    /// Applies `policy`, mapping the non-interactive modes onto the same three
    /// outcomes the prompt produces.
    private static func decide(
        targets: [Target], existing: [String], policy: ExistingFilePolicy, prompt: CollisionPrompt,
        fileManager: FileManager
    ) throws -> CollisionChoice {
        switch policy {
        case .overwrite: return .overwrite
        case .unique: return .unique
        case .error:
            throw HarkError.cantCreate(
                "\(describe(existing)) already exist\(existing.count == 1 ? "s" : "") "
                    + "(use --if-exists overwrite or --if-exists unique, or pick another name).")
        case .ask:
            guard prompt.isAvailable else {
                throw HarkError.cantCreate(
                    "\(describe(existing)) already exist\(existing.count == 1 ? "s" : "") and "
                        + "there is no terminal to ask (use --if-exists overwrite or "
                        + "--if-exists unique).")
            }
            let preview = jointSuffix(for: targets, fileManager: fileManager)
                .map { displayPaths(targets, suffix: $0) } ?? []
            return prompt.ask(existing: existing, uniquePreview: preview) ?? .cancel
        }
    }

    // MARK: Existence

    /// The files among `targets` that already exist, in target order. For a
    /// chunk set this is every `NAME_###.ext` a previous run left behind.
    static func existingFiles(for targets: [Target], fileManager: FileManager = .default) -> [String] {
        targets.flatMap { target -> [String] in
            if target.isChunkSet {
                return existingChunks(base: target.path, fileManager: fileManager)
            }
            return fileManager.fileExists(atPath: target.path) ? [target.path] : []
        }
    }

    /// Existing `--split` chunks for a base path, sorted by their number
    /// (`rec.wav` -> `rec_001.wav`, `rec_002.wav`, …).
    static func existingChunks(base: String, fileManager: FileManager = .default) -> [String] {
        let ns = base as NSString
        let directory = ns.deletingLastPathComponent
        let listing = (try? fileManager.contentsOfDirectory(
            atPath: directory.isEmpty ? "." : directory)) ?? []
        let name = ns.lastPathComponent as NSString
        let ext = name.pathExtension
        let stem = ext.isEmpty ? (name as String) : name.deletingPathExtension
        return listing
            .filter { chunkIndex(of: $0, stem: stem, ext: ext) != nil }
            .sorted { (chunkIndex(of: $0, stem: stem, ext: ext) ?? 0)
                < (chunkIndex(of: $1, stem: stem, ext: ext) ?? 0) }
            .map { directory.isEmpty ? $0 : (directory as NSString).appendingPathComponent($0) }
    }

    /// The chunk number in `filename` for a given stem/extension, or nil when it
    /// isn't a chunk of that base (`rec_001.wav` -> 1).
    private static func chunkIndex(of filename: String, stem: String, ext: String) -> Int? {
        let ns = filename as NSString
        guard ns.pathExtension.lowercased() == ext.lowercased() else { return nil }
        let base = ext.isEmpty ? filename : ns.deletingPathExtension
        guard base.hasPrefix(stem + "_") else { return nil }
        let digits = base.dropFirst(stem.count + 1)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// A directory in an output path can never be written to; fail clearly
    /// instead of letting the encoder report a cryptic I/O error.
    private static func rejectDirectories(_ targets: [Target], fileManager: FileManager) throws {
        for target in targets {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                throw HarkError.cantCreate("'\(target.path)' is a directory, not a file.")
            }
        }
    }

    // MARK: Numbering

    /// Inserts a numbered suffix before the extension: `rec.m4a` -> `rec-1.m4a`.
    /// Deliberately different from `--split`'s `_001` so renumbered outputs are
    /// never confused with chunks.
    static func apply(suffix: Int, to path: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? path : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
    }

    /// The smallest suffix that is free for **every** target, so an audio and
    /// transcript pair keeps a matching name. Nil when none is free.
    static func jointSuffix(for targets: [Target], fileManager: FileManager = .default) -> Int? {
        (1...maxSuffix).first { suffix in
            let renumbered = targets.map {
                Target(path: apply(suffix: suffix, to: $0.path), isChunkSet: $0.isChunkSet)
            }
            return existingFiles(for: renumbered, fileManager: fileManager).isEmpty
        }
    }

    /// The renumbered paths as the user sees them: a `--split` target shows its
    /// first chunk (`rec-1_001.wav`), which is what actually gets written.
    private static func displayPaths(_ targets: [Target], suffix: Int) -> [String] {
        targets.map {
            let renamed = apply(suffix: suffix, to: $0.path)
            return $0.isChunkSet ? chunkPath(base: renamed, index: 1) : renamed
        }
    }

    /// Applies a suffix to every file destination, leaving stdout alone.
    private static func rename(
        _ outputs: Hark.ResolvedOutputs, suffix: Int
    ) -> (outputs: Hark.ResolvedOutputs, paths: [String]) {
        var paths: [String] = []
        var audio = outputs.audio
        if case .file(let path)? = outputs.audio {
            let renamed = apply(suffix: suffix, to: path)
            audio = .file(renamed)
            paths.append(renamed)
        }
        var transcript = outputs.transcript
        if case .file(let path)? = outputs.transcript {
            let renamed = apply(suffix: suffix, to: path)
            transcript = .file(renamed)
            paths.append(renamed)
        }
        return (Hark.ResolvedOutputs(audio: audio, transcript: transcript), paths)
    }

    // MARK: Overwrite

    /// Removes stale `--split` chunks so a shorter run can't leave a directory
    /// holding two sessions interleaved. Plain files are truncated by their
    /// writer, so nothing to do there. Returns the files removed.
    @discardableResult
    private static func purge(_ targets: [Target], fileManager: FileManager) throws -> [String] {
        var removed: [String] = []
        for target in targets where target.isChunkSet {
            let chunks = existingChunks(base: target.path, fileManager: fileManager)
            guard !chunks.isEmpty else { continue }
            Log.notice("removing \(chunks.count) existing chunk\(chunks.count == 1 ? "" : "s"): "
                + "\(describe(chunks, countSuffix: false))")
            for chunk in chunks {
                do {
                    try fileManager.removeItem(atPath: chunk)
                } catch {
                    throw HarkError.cantCreate("cannot remove existing chunk '\(chunk)': \(error)")
                }
            }
            removed += chunks
        }
        return removed
    }

    // MARK: Self-overwrite

    /// Rejects an output that is also the input (`-i rec.wav -a rec.wav`), which
    /// would truncate the file being read, and an audio/transcript pair pointing
    /// at the same file.
    static func checkDistinct(
        input: String?, outputs: Hark.ResolvedOutputs, fileManager: FileManager = .default
    ) throws {
        var audioPath: String?
        var transcriptPath: String?
        if case .file(let path)? = outputs.audio { audioPath = path }
        if case .file(let path)? = outputs.transcript { transcriptPath = path }

        if let input, input != "-" {
            for output in [audioPath, transcriptPath].compactMap({ $0 })
            where isSameFile(input, output, fileManager: fileManager) {
                throw HarkError.usage(
                    "input and output are the same file ('\(output)'); write to a different path.")
            }
        }
        if let audioPath, let transcriptPath,
            isSameFile(audioPath, transcriptPath, fileManager: fileManager)
        {
            throw HarkError.usage(
                "-a and -t point at the same file ('\(audioPath)'); give them different paths.")
        }
    }

    /// Whether two paths name the same file: identical after normalization, or
    /// the same inode when both already exist (catches links and `./` forms).
    static func isSameFile(_ a: String, _ b: String, fileManager: FileManager = .default) -> Bool {
        let left = URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL
        let right = URL(fileURLWithPath: (b as NSString).expandingTildeInPath).standardizedFileURL
        if left.path == right.path { return true }
        guard let lhs = try? fileManager.attributesOfItem(atPath: left.path),
            let rhs = try? fileManager.attributesOfItem(atPath: right.path),
            let lhsID = lhs[.systemFileNumber] as? Int, let rhsID = rhs[.systemFileNumber] as? Int,
            let lhsDevice = lhs[.systemNumber] as? Int, let rhsDevice = rhs[.systemNumber] as? Int
        else { return false }
        return lhsID == rhsID && lhsDevice == rhsDevice
    }

    // MARK: Messages

    /// Renders a path list for a message: `'a.wav'`, `'a.wav' and 'b.txt'`,
    /// `'a_001.wav', 'a_002.wav' and 'a_003.wav'`, eliding long chunk runs.
    static func describe(_ paths: [String], countSuffix: Bool = true) -> String {
        let quoted = paths.map { "'\($0)'" }
        switch quoted.count {
        case 0: return "(none)"
        case 1: return quoted[0]
        case 2: return "\(quoted[0]) and \(quoted[1])"
        case 3...4: return quoted.dropLast().joined(separator: ", ") + " and \(quoted.last!)"
        default:
            return "\(quoted[0]) … \(quoted.last!)" + (countSuffix ? " (\(quoted.count) files)" : "")
        }
    }
}
