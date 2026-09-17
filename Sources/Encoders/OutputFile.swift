import Foundation

/// Opening output files for writing.
public enum OutputFile {
    /// Opens `url` for writing, creating it if absent and truncating it if not,
    /// positioned at offset 0. Returns nil when it cannot be opened.
    ///
    /// A single `open(2)` with `O_CREAT|O_TRUNC` rather than
    /// `FileManager.createFile` + `FileHandle(forWritingTo:)`: the latter is two
    /// steps, and because `FileHandle` does **not** truncate, a failed create
    /// would silently leave the writer laying new audio over an existing file's
    /// stale trailing bytes (a corrupt hybrid).
    public static func truncatingHandle(at url: URL) -> FileHandle? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
